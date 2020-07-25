import looker_sdk
import pickle
import requests
import json
import urllib.parse
import tempfile
import tarfile
import shutil
import os
import subprocess
import time
from backoff_utils import apply_backoff, strategies
from fabric import Connection
from git import Repo
from bs4 import BeautifulSoup
from jinja2 import Template
from looker_sdk import models
from pathlib import Path


def create_api_creds(output_dict):

    url = output_dict["host_url"]["value"]
    user = output_dict["user"]["value"]
    passw = output_dict["pass"]["value"]

    # The user and pass entries need to be url encoded
    encoded_user = urllib.parse.quote(user)
    encoded_pass = urllib.parse.quote(passw)

    # We'll use a session to keep track of the cookies easily
    s = requests.Session()

    # Seed the csrf value in the cookies
    s.get(f"{url}/login/email")

    csrf = s.cookies.get("CSRF-TOKEN")

    # Log in with the established csrf token
    header = {"Content-Type": "application/x-www-form-urlencoded"}
    data = f"email={encoded_user}&password={encoded_pass}&csrf-token={csrf}"
    s.post(f"{url}/login", headers=header, data=data)

    # Now we need the authenticated csrf token
    r = s.get(f"{url}/folders/home")

    # It's located in a meta tag, so we need to grab it
    soup = BeautifulSoup(r.text, "html.parser")
    auth_csrf = soup.find("meta", attrs={"name": "csrf-token"})["content"]

    # We'll use that token to post to Looker's internal API to create API keys
    csrf_header = {"X-CSRF-Token": auth_csrf}
    s.post(f"{url}/admin/users/api3_key/1", headers=csrf_header)

    # To fetch the keys we need to parse the table in the html
    r = s.get(f"{url}/admin/users/api3_key/1", headers=csrf_header)

    api_soup = BeautifulSoup(r.text, "html.parser")
    table = api_soup.find("table")
    table_rows = table.find_all("tr")
    row = table_rows[1]
    client_id = [i.text for i in row][0]
    client_secret = row.find("lk-hidden-field")["content"].replace("'", "")

    # Now we render our ini template file with the api keys for future SDK use
    with open("ini_template.ini") as f:
        ini_template = f.read()

    ini_parsed = Template(ini_template).render(url=url, client_id=client_id, client_secret=client_secret)

    with open("looker.ini", "w") as f:
        f.write(ini_parsed)

    return (client_id, client_secret)


def create_db_connection(con_file):

    # The saved connection must be a pre-pickled WriteDBConnection object
    with open(con_file, "rb") as f:
        db = pickle.load(f)

    sdk = looker_sdk.init31()
    sdk.create_connection(db)


def create_project(project_name):

    project = models.WriteProject(name=project_name)
    sdk = looker_sdk.init31()

    # We need to enter dev mode to create a project
    sdk.update_session(models.WriteApiSession(workspace_id="dev"))

    resp = sdk.create_project(project)

    # Now we update the project and set it to a bare repo
    sdk.update_project(resp.id, models.WriteProject(git_service_name="bare"))
    return resp.id


def upload_and_push(tar, connection, dest):
    connection.put(tar, "/home/ubuntu")
    connection.run("tar zxvf lookml.tgz")
    connection.run("cd lookml && git init")
    connection.run(f"cd lookml && git remote add origin {dest}")
    connection.run("cd lookml && git add --all && git commit -m 'lookml files'")
    connection.run("cd lookml && git fetch && git rebase origin/master")
    connection.run("cd lookml && sudo git push origin master")


def seed_project_files(repo, project_id, output_dict):

    nfs_flag = output_dict["nfs_flag"]["value"]
    key = output_dict["key"]["value"]
    client = output_dict["node_public_dns"]["value"][0]
    host_url = output_dict["host_url"]["value"]

    key_path = os.path.join(str(Path.home()), ".ssh", key)
    ckwargs = {"key_filename": key_path}

    # set the destination based on the nfs flag
    if nfs_flag == 1:
        dest = f"/mnt/lookerfiles/bare_models/{project_id}.git"
    else:
        dest = f"/home/looker/looker/bare_models/{project_id}.git"

    con = Connection(client, "ubuntu", connect_kwargs=ckwargs)
    with tempfile.TemporaryDirectory() as d:
        repo_path = os.path.join(d, "repo")
        os.mkdir(repo_path)

        # clone the repo
        Repo.clone_from(repo, repo_path)

        # remove the git info before sending to remote
        shutil.rmtree(os.path.join(repo_path, ".git/"))

        # tar it
        lookml_tar = os.path.join(d, "lookml.tgz")
        with tarfile.open(lookml_tar, "w:gz") as tar:
            tar.add(repo_path, arcname="lookml")

        # send it
        upload_and_push(lookml_tar, con, dest)

    # call the deploy webhook
    requests.get(f"{host_url}/webhooks/projects/{project_id}/deploy")


def create_model_entries(project_id):

    sdk = looker_sdk.init31()
    files = sdk.all_project_files(project_id)
    lkml_models = [file.title.split(".")[0] for file in files if file.type == "model"]

    for l in lkml_models:
        new_model = models.WriteLookmlModel(name=l, project_name=project_id, unlimited_db_connections=True)
        sdk.create_lookml_model(new_model)


def send_content(output_dict, client_id, client_secret, dashboard_json):
    url = output_dict["host_url"]["value"].replace("https://", "")
    gzr_command = [
        "gzr",
        "dashboard",
        "import",
        dashboard_json,
        "1",
        "--host",
        url,
        "--client_id",
        client_id,
        "--client_secret",
        client_secret,
        "--force"
    ]

    subprocess.run(gzr_command)


@apply_backoff(strategies.Exponential, max_tries=8)
def is_alive(output_dict):
    url = output_dict["host_url"]["value"]

    requests.get(f"{url}/alive")


if __name__ == "__main__":

    # parse the output json
    with open("output.json") as f:
        output_dict = json.load(f)

    # set the source repo
    source_repo = "https://github.com/JCPistell/partner_homepage_template.git"

    # set dashboard
    dash = "Dashboard_1_Overview.json"

    # wait for the instance to come up
    print("sleeping")
    time.sleep(30)
    print("done sleeping...")
    is_alive(output_dict)

    # execute
    client_id, client_secret = create_api_creds(output_dict)
    create_db_connection("db.p")
    project_id = create_project("thelook")
    seed_project_files(source_repo, project_id, output_dict)
    create_model_entries(project_id)
    send_content(output_dict, client_id, client_secret, dash)
