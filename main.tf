terraform {
    required_version = "~>1.3"
    required_providers {
        aws = {
            source = "hashicorp/aws",
            version = ">4.1"
        }
    }
}

variable "root_module_path" {
    description = <<EOT
        A reasonably precise directory path or otherwise recognizable name of the 
        root module which controls these resources. Makes correlating resources 
        with the module that deployed them possible when viewing resources in AWS.
    EOT
    type = string
    default = "Pacemaker"
}

variable "az_count" {
    description = <<EOT
        Amount of availability zones to install the cluster to. Referenced by ID, 
        so order should not change. Only selects currently available zones.
    EOT
    type = number
    default = 3
}

variable "tags" {
    description = "Tags which get applied to all resources."
    type = map(string)
    default = {}
}

variable "vpc_cidr" {
    description = "IPv4 CIDR block in which all subnets will be created."
    type = string
    default = "10.4.20.0/22"
}

variable "private_public_subnet_mask_ratio" {
    description = <<EOT
        Given the VPC CIDR block and the amount of zones requested, 
        use this ratio to determine private to public subnet density 
        relative to VPC CIDR density. Used in automatic subnet size calculation.
    EOT
    type = string
    default = "5:2"
}

locals {
    azs = [ for az in range(var.az_count) : data.aws_availability_zones.current.id[az] ]

    tags = merge(
        {
            managed_by = "Terraform",
            terraform_root_module_path = var.root_module_path,
            Name = "Pacemaker"
        },
        var.tags
    )

    vpc_cidr_mask_bits = split("/", var.vpc_cidr)[1]

    private_subnets_newbits_unlimited = (32 - local.vpc_cidr_mask_bits) - floor(
        (
            32 - local.vpc_cidr_mask_bits
        ) / (
            split(":", var.private_public_subnet_mask_ratio)[
                0
            ] + split(":", var.private_public_subnet_mask_ratio)[
                1
            ]
        ) * split(":", var.private_public_subnet_mask_ratio)[0]
    )


    public_subnets_newbits_unlimited = (32 - local.vpc_cidr_mask_bits) - floor(
        (
            32 - local.vpc_cidr_mask_bits
        ) / (
            split(":", var.private_public_subnet_mask_ratio)[
                0
            ] + split(":", var.private_public_subnet_mask_ratio)[
                1
            ]
        ) * split(":", var.private_public_subnet_mask_ratio)[1]
    )

    private_subnets_newbits = local.private_subnets_newbits_unlimited - (
        max(
            28,
            local.vpc_cidr_mask_bits + local.private_subnets_newbits_unlimited
        ) - 28
    )

    public_subnets_newbits = local.public_subnets_newbits_unlimited - (
        max(
            28,
            local.vpc_cidr_mask_bits + local.public_subnets_newbits_unlimited
        ) - 28
    )

}

data "aws_availability_zones" "current" {
    state = "available"
}

data "aws_ami" "ubuntu" {
    most_recent = true

    filter {
        name = "name"
        values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
    }

    owners = ["099720109477"]
}

module "private_subnets" {
    source = "hashicorp/subnets/cidr"

    base_cidr_block = var.vpc_cidr

    networks = [
        for zone in local.azs : {
            name = zone,
            new_bits = local.private_subnets_newbits
        }
    ]
}

module "public_subnets" {
    source = "hashicorp/subnets/cidr"

    base_cidr_block = var.vpc_cidr

    networks = concat(
        [
            for subnet in module.private_subnets.networks : {
                name = null
                new_bits = local.private_subnets_newbits
            }
        ],
        [
            for zone in local.azs : {
                name = zone,
                new_bits = local.public_subnets_newbits
            }
        ]
    )
}

module "vpc" {
    source = "terraform-aws-modules/vpc/aws"

    name = local.tags.Name
    cidr = var.vpc_cidr

    azs  = local.azs
    private_subnets = values(module.private_subnets.network_cidr_blocks)
    public_subnets = values(module.private_subnets.network_cidr_blocks)

    enable_nat_gateway = true
    single_nat_gateway = false
    one_nat_gateway_per_az = true

    tags = local.tags
}

resource "aws_route53_zone" "cluster" {
    name = "cluster.internal"
    force_destroy = true
    tags = local.tags

    vpc {
        vpc_id = module.vpc.vpc_id
    }
}

resource "aws_route53_record" "corosync" {
    count = var.az_count

    zone_id = aws_route53_zone.cluster.zone_id
    name = format("corosync-%s.cluster.internal", count.index)
    type = "A"
    records = [aws_instance.corosync[count.index].private_ip]
}

resource "aws_iam_instance_profile" "corosync" {
    name = local.tags.Name
    role = aws_iam_role.corosync.name
}

resource "aws_iam_role" "corosync" {
    name = local.tags.Name
    path = "/"

    assume_role_policy = jsonencode(
        {
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Action": "sts:AssumeRole",
                    "Principal": {
                       "Service": "ec2.amazonaws.com"
                    },
                    "Effect": "Allow",
                    "Sid": ""
                }
            ]
        }
    )
}

resource "aws_iam_role_policy_attachment" "ssm" {
    role = aws_iam_role.corosync.name
    policy_arn = "AmazonSSMManagedInstanceCore"
}

resource "aws_security_group" "corosync" {
    name = local.tags.Name
    description = "Allow required incoming ports for corosync cluster nodes."
    vpc_id = module.vpc.vpc_id

    ingress {
        description = "SSH from VPC"
        from_port = 22
        to_port = 22
        protocol = "tcp"
        cidr_blocks = [var.vpc_cidr]
    }

    egress {
        from_port        = 0
        to_port          = 0
        protocol         = "-1"
        cidr_blocks      = ["0.0.0.0/0"]
        ipv6_cidr_blocks = ["::/0"]
    }
}
    

resource "aws_instance" "corosync" {
    count = var.az_count

    ami = data.aws_ami.ubuntu.id
    instance_type = "t3.micro"
    availability_zone = local.azs[count.index]

    ephemeral_block_device {
        device_name = "drbd"
    }

    tags = merge(
        local.tags,
        { Name = format("corosync-%s", count.index) }
    )

    user_data = <<EOT
# Install Cororsync, Pacemaker, crmsh, DRBD.
# Configure Corosync
# Configure DRBD
# Start daemons
    EOT
}

# Deliver a CIB to the cluster via an SSH provider, SSM, or lambda.
resource "null_resource" "cib" {
    depends_on = [aws_instance.corosync]
}
