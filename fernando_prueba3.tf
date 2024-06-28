terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.53.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Creacion de VPC
module "my_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = false

  tags = {
    Terraform   = "true"
    Environment = "prd"
  }
}

# Grupo de Seguridad
resource "aws_security_group" "my_sg" {
  name        = "f-security-group"
  description = "Allow HTTP, HTTPS, and SSH traffic"
  vpc_id      = module.my_vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "f-security-group"
    Terraform   = "true"
    Environment = "prd"
  }
}

# Bucket S3 con ID Aleatorio
resource "random_id" "bucket" {
  byte_length = 8
}

resource "aws_s3_bucket" "mybucket" {
  bucket = "mybucket-${random_id.bucket.hex}"

  tags = {
    Name = "mybucket-${random_id.bucket.hex}"
  }
}

resource "aws_s3_bucket_public_access_block" "mybucket" {
  bucket = aws_s3_bucket.mybucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "time_sleep" "wait_10_seconds" {
  depends_on      = [aws_s3_bucket.mybucket]
  create_duration = "10s"
}

resource "aws_s3_bucket_policy" "mybucket" {
  bucket     = aws_s3_bucket.mybucket.id
  policy     = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": ["s3:GetObject"],
      "Resource": [
        "arn:aws:s3:::${aws_s3_bucket.mybucket.id}/*"
      ]
    }
  ]
}
EOF
  depends_on = [time_sleep.wait_10_seconds]
}

resource "aws_s3_object" "index" {
  bucket = aws_s3_bucket.mybucket.id
  key    = "index.php"
  source = "index.php"
  content_type = "text/html"
}

# Sistema de Archivos EFS
resource "aws_efs_file_system" "my_efs" {
  creation_token = "my-efs-token"
  tags = {
    Name = "my-efs"
  }
}

resource "aws_efs_mount_target" "my_efs_mount_target" {
  count           = length(module.my_vpc.public_subnets)
  file_system_id  = aws_efs_file_system.my_efs.id
  subnet_id       = element(module.my_vpc.public_subnets, count.index)
  security_groups = [aws_security_group.my_sg.id]
}

# Instancias EC2
resource "aws_instance" "f_instance" {
  count         = 3
  ami           = "ami-01b799c439fd5516a"
  instance_type = "t2.micro"
  key_name      = "vockey"
  subnet_id     = element(module.my_vpc.public_subnets, count.index)
  vpc_security_group_ids = [aws_security_group.my_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y amazon-efs-utils
              yum install -y httpd php
              mkdir -p /var/www/html
              mount -t efs -o tls ${aws_efs_file_system.my_efs.id}:/ /var/www/html
              aws s3 cp s3://${aws_s3_bucket.mybucket.bucket}/index.php /var/www/html/index.php
              systemctl start httpd
              systemctl enable httpd
            EOF

  tags = {
    Name = "my-instance-${count.index}"
  }
}

# Load Balancer (ALB)
resource "aws_lb" "f_lb" {
  name               = "prueba3-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.my_sg.id]
  subnets            = module.my_vpc.public_subnets

  tags = {
    Name = "prueba3-lb"
  }
}

resource "aws_lb_target_group" "f_target_group" {
  name     = "my-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.my_vpc.vpc_id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name = "my-target-group"
  }
}

resource "aws_lb_listener" "Listener_F" {
  load_balancer_arn = aws_lb.f_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.f_target_group.arn
  }
}

resource "aws_lb_target_group_attachment" "f_target_group_attachment" {
  count            = 3
  target_group_arn = aws_lb_target_group.f_target_group.arn
  target_id        = aws_instance.f_instance[count.index].id
  port             = 80
}
