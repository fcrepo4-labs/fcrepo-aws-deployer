//
//
//

provider "aws" {
  profile    = var.aws_profile
  region     = var.aws_region
}

resource "aws_iam_role" "fcrepo" {

  name                  = "${var.app_name}-${var.app_environment}-role"
  force_detach_policies = true
  assume_role_policy    = <<EOF
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
EOF

  tags = {
    Name = "${var.app_name}-${var.app_environment}-role"
  }
}

resource "aws_iam_role_policy_attachment" "attach_web_tier" {

  role       = aws_iam_role.fcrepo.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWebTier"
}

resource "aws_iam_role_policy_attachment" "attach_docker" {

  role       = aws_iam_role.fcrepo.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkMulticontainerDocker"
}

resource "aws_iam_role_policy_attachment" "attach_worker_tier" {

  role       = aws_iam_role.fcrepo.name
  policy_arn = "arn:aws:iam::aws:policy/AWSElasticBeanstalkWorkerTier"
}


resource "aws_iam_instance_profile" "fcrepo" {

  name = "${var.app_name}-${var.app_environment}-instance-profile"
  role = aws_iam_role.fcrepo.name
}

resource "aws_vpc" "fcrepo" {
 cidr_block           = "10.0.0.0/16"
 enable_dns_hostnames =  true

 tags = {
    Name = "${var.app_name}-${var.app_environment}-vpc"
  }
}

resource "aws_subnet" "fcrepo_a" {

 vpc_id            = aws_vpc.fcrepo.id
 cidr_block        = "10.0.0.0/24"
 availability_zone = "${var.aws_region}a"

 tags = { 
    Name = "_${var.app_name}-${var.app_environment}-subnet-a"
  }
}

resource "aws_subnet" "fcrepo_b" {

 vpc_id           = aws_vpc.fcrepo.id
 cidr_block       = "10.0.1.0/24"
 availability_zone = "${var.aws_region}b"

 tags = {
    Name = "${var.app_name}-${var.app_environment}-subnet-b"
  }
}

resource "aws_route_table" "fcrepo" {

  vpc_id = aws_vpc.fcrepo.id

  tags = { 
    Name = "${var.app_name}-${var.app_environment}-route-table"
  }
}

resource "aws_db_subnet_group" "fcrepo_db_subnet_group" {

  name       = "${var.app_name}-${var.app_environment}-db-subnet-group"
  subnet_ids = [aws_subnet.fcrepo_a.id, aws_subnet.fcrepo_b.id]

  tags = {
    Name = "${var.app_name}-${var.app_environment}-db-subnet-group"
  }
}

resource "aws_security_group" "fcrepo_database" {

  vpc_id = aws_vpc.fcrepo.id
  name   = "${var.app_name}-${var.app_environment}-db-sg"

  ingress {
    cidr_blocks = ["10.0.0.0/24"]
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name   = "${var.app_name}-${var.app_environment}-db-sg"
  }
}

resource "aws_db_instance" "fcrepo" {

  depends_on                = [aws_db_subnet_group.fcrepo_db_subnet_group]

  identifier                = "${var.app_name}-${var.app_environment}-db-instance"
  allocated_storage         = 20
  storage_type              = "gp2"
  engine                    = var.db_engine == "postgresql" ?  "postgres" :  var.db_engine
  engine_version            = var.db_version
  port                      = var.db_port
  instance_class            = var.db_instance_class
  name                      = var.db_name
  username                  = var.db_username
  password                  = var.db_password
  db_subnet_group_name      = aws_db_subnet_group.fcrepo_db_subnet_group.name
  vpc_security_group_ids    =  [ aws_security_group.fcrepo_database.id ]
  skip_final_snapshot       = "true"
  final_snapshot_identifier = "final-${var.app_name}-${var.app_environment}-db"

  tags = {
    Name       = "${var.app_name}-${var.app_environment}-db-instance"
  }
}


resource "aws_route_table_association" "fcrepo" {

  subnet_id      = aws_subnet.fcrepo_a.id
  route_table_id = aws_route_table.fcrepo.id
}

resource "aws_route" "route2igc" {

  route_table_id            = aws_route_table.fcrepo.id
  destination_cidr_block    = "0.0.0.0/0"
  gateway_id                = aws_internet_gateway.fcrepo.id
}

resource "aws_internet_gateway" "fcrepo" {

  vpc_id = aws_vpc.fcrepo.id
}

resource "aws_security_group" "fcrepo" {

  vpc_id = aws_vpc.fcrepo.id

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 8080 
    to_port     = 8080
    protocol    = "tcp"
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-${var.app_environment}-security-group"
  }
}

resource "aws_cloudwatch_log_group" "fcrepo" {

  name = "${var.app_name}-${var.app_environment}"

  tags = {
    Application = "${var.app_name}-${var.app_environment}"
  }
}

resource "null_resource" "prepare_beanstalk_zip" {

  provisioner "local-exec" {
    command = <<EOT
                mkdir output
		sed "s/{{fcrepo.version}}/$FCREPO_VERSION/g" elasticbeanstalk/Dockerrun.aws.json.template > output/Dockerrun.aws.json
                cd output
                zip fcrepo-$FCREPO_VERSION-eb-docker.zip Dockerrun.aws.json
  EOT
      environment = {
         FCREPO_VERSION = "${var.fcrepo_version}"
      }
  }
}

resource "aws_s3_bucket" "default" {

  depends_on = [null_resource.prepare_beanstalk_zip]

  bucket     = var.aws_artifact_bucket_name
  acl        = "private"

  tags = {
    Name        = "Fedora EB artifacts"
  }
}

resource "aws_s3_bucket_object" "eb_docker_zip" {

  bucket = aws_s3_bucket.default.id
  key    = "fcrepo-${var.fcrepo_version}-eb-docker.zip"
  source = "output/fcrepo-${var.fcrepo_version}-eb-docker.zip"
}


resource "aws_elastic_beanstalk_application" "fcrepo" {

  name        = "${var.app_name}-${var.app_environment}"
  description = "Fedora Repository"

  tags = {
    Name= "${var.app_name}-${var.app_environment}-beanstalk-application"
  }
}

resource "aws_elastic_beanstalk_application_version" "default" {

  name        = "${var.app_name}-${var.app_environment}-${var.app_version}"
  application = aws_elastic_beanstalk_application.fcrepo.name
  description = "Application version created by Terraform"
  bucket      = aws_s3_bucket.default.id
  key         = aws_s3_bucket_object.eb_docker_zip.id
}


resource "aws_elastic_beanstalk_environment" "fcrepo" {

  depends_on =  [aws_elastic_beanstalk_application_version.default]

  name                = "${var.app_name}-${var.app_environment}"
  application         = aws_elastic_beanstalk_application.fcrepo.name
  solution_stack_name = "64bit Amazon Linux 2 v3.2.2 running Docker"
  version_label       = aws_elastic_beanstalk_application_version.default.name

  setting {
    namespace = "aws:ec2:vpc"
    name      = "VPCId"
    value     = aws_vpc.fcrepo.id
  }

  setting {
    namespace = "aws:ec2:vpc"
    name      = "Subnets"
    value     = aws_subnet.fcrepo_a.id
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "SingleInstance"
  }

  setting {
    namespace = "aws:elasticbeanstalk:environment"
    name      = "EnvironmentType"
    value     = "SingleInstance"
  }

  setting {
    namespace = "aws:ec2:instances"
    name      = "InstanceTypes"
    value     = var.instance_class
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "IamInstanceProfile"
    value     = aws_iam_instance_profile.fcrepo.name
  }

  setting {
    namespace = "aws:autoscaling:launchconfiguration"
    name      = "EC2KeyName"
    value     = var.ec2_keypair
  }

  setting {
    namespace = "aws:elasticbeanstalk:application:environment"
    name      = "CATALINA_OPTS"
    value     = "-Dfcrepo.db.url=jdbc:${var.db_engine}://${aws_db_instance.fcrepo.endpoint}/${var.db_name} -Dfcrepo.db.user=${aws_db_instance.fcrepo.username} -Dfcrepo.db.password=${aws_db_instance.fcrepo.password}"
  }
}

//
// end of file
//