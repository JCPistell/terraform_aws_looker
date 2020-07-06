provider "aws" {
  region = var.aws_region
  shared_credentials_file = "~/.aws/credentials"
  profile = "sandbox"
  version = "~> 2.0"
}

provider random {
  version = "~> 2.0"
}

provider tls {
  version = "~> 2.0"
}

# Get the latest ubuntu ami for the above region
data "aws_ami" "ubuntu" {
    most_recent = true

    filter {
        name   = "name"
        values = ["ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
    }

    filter {
        name   = "virtualization-type"
        values = ["hvm"]
    }

    owners = ["099720109477"] # Canonical
}


# Create a virtual private cloud to contain all these resources
resource "aws_vpc" "looker-env" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
}

# Create elastic IP addresses for our ec2 instances
resource "aws_eip" "ip-looker-env" {
  depends_on = [aws_instance.looker-instance]
  count      = var.instances
  instance   = element(aws_instance.looker-instance.*.id, count.index)
  vpc        = true
}

# Get a list of all availability zones in this region, we need it to create subnets
data "aws_availability_zones" "available" {}

# Create subnets within each availability zone
resource "aws_subnet" "subnet-looker" {
  count                   = length(data.aws_availability_zones.available.names)
  vpc_id                  = aws_vpc.looker-env.id
  cidr_block              = "10.0.${length(data.aws_availability_zones.available.names) + count.index}.0/24"
  map_public_ip_on_launch = true
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
}

# Create the inbound security rules
resource "aws_security_group" "ingress-all-looker" {
  name = "allow-all-sg"
  vpc_id = aws_vpc.looker-env.id

  # Looker cluster communication
  ingress {
    cidr_blocks = [
      "10.0.0.0/16" # (private to subnet)
    ]
    from_port = 61616
    to_port = 61616
    protocol = "tcp"
  }

  # Looker cluster communication
  ingress {
    cidr_blocks = [
      "10.0.0.0/16" # (private to subnet)
    ]
    from_port = 1551
    to_port = 1551
    protocol = "tcp"
  }

  # SSH
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 22
    to_port = 22
    protocol = "tcp"
  }

  # API
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 19999
    to_port = 19999
    protocol = "tcp"
  }

  # Monitoring
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 9910
    to_port = 9910
    protocol = "tcp"
  }

  # HTTP to reach single nodes
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 9999
    to_port = 9999
    protocol = "tcp"
  }

  # HTTPS
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 443
    to_port = 443
    protocol = "tcp"
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Choose an existing public/private key pair to use for authentication
resource "aws_key_pair" "key" {
  key_name   = "key${aws_vpc.looker-env.id}"
  public_key = file("~/.ssh/${var.key}.pub") # this file must be an existing public key!
}

# Create ec2 instances for the Looker application servers
resource "aws_instance" "looker-instance" {
  count         = var.instances
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.ec2_instance_type
  vpc_security_group_ids = ["${aws_security_group.ingress-all-looker.id}"]
  subnet_id = aws_subnet.subnet-looker.0.id
  associate_public_ip_address = true
  key_name = aws_key_pair.key.key_name

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "30"
    delete_on_termination = "true"
  }

  ebs_block_device {
    device_name           = "/dev/sdg"
    volume_type           = "gp2"
    volume_size           = "30"
  }

  connection {
    host = self.public_dns
    type = "ssh"
    user = "ubuntu"
    private_key = file("~/.ssh/${var.key}")
    timeout = "1m"
    agent = true
  }

  provisioner "file" {
    source      = var.provisioning_script
    destination = "/tmp/${var.provisioning_script}"
  }
  provisioner "remote-exec" {
    inline = [
      "sleep 10",

      "export LOOKER_LICENSE_KEY=${var.looker_license_key}",
      "export LOOKER_TECHNICAL_CONTACT_EMAIL=${var.technical_contact_email}",
      "export LOOKER_PASSWORD=${random_string.password.result}",
      "export HOST_URL=${self.public_dns}",

      "chmod +x /tmp/${var.provisioning_script}",
      "/bin/bash /tmp/${var.provisioning_script}",
   ]
 }

  lifecycle {
    # Ignore changes to these arguments because of known issues with the Terraform AWS provider:
    ignore_changes = [private_ip, root_block_device, ebs_block_device]
  }
}

# Create an internet gateway, a routing table, and route associations
resource "aws_internet_gateway" "looker-env-gw" {
  vpc_id = aws_vpc.looker-env.id
}

resource "aws_route_table" "route-table-looker-env" {
  vpc_id = aws_vpc.looker-env.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.looker-env-gw.id
  }
}

resource "aws_route_table_association" "subnet-association" {
  subnet_id      = aws_subnet.subnet-looker.0.id
  route_table_id = aws_route_table.route-table-looker-env.id
}

data "aws_route53_zone" "zone" {
  name = "${var.domain}."
  private_zone = false
}

resource "aws_acm_certificate" "dev-cert" {
  domain_name = "jcp-dev.${var.domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "prod-cert" {
  domain_name = "jcp-prod.${var.domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "dev-cert_validation" {
  name = aws_acm_certificate.dev-cert.domain_validation_options.0.resource_record_name
  type = aws_acm_certificate.dev-cert.domain_validation_options.0.resource_record_type
  zone_id = data.aws_route53_zone.zone.zone_id
  records = ["${aws_acm_certificate.dev-cert.domain_validation_options.0.resource_record_value}"]
  ttl = 60
}

resource "aws_route53_record" "prod-cert_validation" {
  name = aws_acm_certificate.prod-cert.domain_validation_options.0.resource_record_name
  type = aws_acm_certificate.prod-cert.domain_validation_options.0.resource_record_type
  zone_id = data.aws_route53_zone.zone.zone_id
  records = ["${aws_acm_certificate.prod-cert.domain_validation_options.0.resource_record_value}"]
  ttl = 60
}

resource "aws_acm_certificate_validation" "dev-cert" {
  certificate_arn = aws_acm_certificate.dev-cert.arn
  validation_record_fqdns = ["${aws_route53_record.dev-cert_validation.fqdn}"]
}

resource "aws_acm_certificate_validation" "prod-cert" {
  certificate_arn = aws_acm_certificate.prod-cert.arn
  validation_record_fqdns = ["${aws_route53_record.prod-cert_validation.fqdn}"]
}

# Create a load balancer to route traffic to the instances
resource "aws_elb" "dev-looker-elb" {
  name                        = "looker-elb-dev"
  subnets                     = ["${aws_subnet.subnet-looker.0.id}"]
  internal                    = "false"
  security_groups             = ["${aws_security_group.ingress-all-looker.id}"]
  instances                   = ["${aws_instance.looker-instance.0.id}"]
  cross_zone_load_balancing   = true
  idle_timeout                = 3600
  connection_draining         = false
  connection_draining_timeout = 300

  listener {
    instance_port      = "9999"
    instance_protocol  = "https"
    lb_port            = "443"
    lb_protocol        = "https"
    ssl_certificate_id = aws_acm_certificate.dev-cert.arn
  }

  listener {
    instance_port      = "19999"
    instance_protocol  = "https"
    lb_port            = "19999"
    lb_protocol        = "https"
    ssl_certificate_id = aws_acm_certificate.dev-cert.arn
  }

  listener {
    instance_port      = "9910"
    instance_protocol  = "http"
    lb_port            = "9910"
    lb_protocol        = "http"
  }

  health_check {
    target              = "https:9999/alive"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }
}

resource "aws_elb" "prod-looker-elb" {
  name                        = "looker-elb-prod"
  subnets                     = ["${aws_subnet.subnet-looker.0.id}"]
  internal                    = "false"
  security_groups             = ["${aws_security_group.ingress-all-looker.id}"]
  instances                   = ["${aws_instance.looker-instance.1.id}"]
  cross_zone_load_balancing   = true
  idle_timeout                = 3600
  connection_draining         = false
  connection_draining_timeout = 300

  listener {
    instance_port      = "9999"
    instance_protocol  = "https"
    lb_port            = "443"
    lb_protocol        = "https"
    ssl_certificate_id = aws_acm_certificate.prod-cert.arn
  }

  listener {
    instance_port      = "19999"
    instance_protocol  = "https"
    lb_port            = "19999"
    lb_protocol        = "https"
    ssl_certificate_id = aws_acm_certificate.prod-cert.arn
  }

  listener {
    instance_port      = "9910"
    instance_protocol  = "http"
    lb_port            = "9910"
    lb_protocol        = "http"
  }

  health_check {
    target              = "https:9999/alive"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }
}

resource "aws_route53_record" "dev-looker-dns" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name = "jcp-dev.lookersandbox.com"
  type = "A"

  alias {
    name = aws_elb.dev-looker-elb.dns_name
    zone_id = aws_elb.dev-looker-elb.zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "prod-looker-dns" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name = "jcp-prod.lookersandbox.com"
  type = "A"

  alias {
    name = aws_elb.prod-looker-elb.dns_name
    zone_id = aws_elb.prod-looker-elb.zone_id
    evaluate_target_health = false
  }
}

# Generate a random Looker password
resource "random_string" "password" {
  length = 10
  special = true
  number = true
  min_numeric = 1
  min_special = 1
  min_upper = 1
  override_special = "#%^*-="
}

output "Details" {
  value = "\n\nLooker password is ${random_string.password.result}\n\nStarted DEV\nhttps://${aws_eip.ip-looker-env.0.public_dns}:9999\nssh -i ~/.ssh/${var.key} ubuntu@${aws_eip.ip-looker-env.0.public_dns}\n\nStarted PROD\nhttps://${aws_eip.ip-looker-env.1.public_dns}:9999\nssh -i ~/.ssh/${var.key} ubuntu@${aws_eip.ip-looker-env.1.public_dns}\n\nYou will need to wait a few minutes for the instances to become available.\n\n"
}
