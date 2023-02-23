# Define variables
variable "aws_region" {
  default = "eu-west-2"
}

variable "instance_type" {
  default = "t2.medium"
}

variable "ami_id" {
  default = "ami-08ff8b7a92e1663d5"
}

provider "aws" {
  access_key = "AKIA3PBFSZQWLFDWV4NW"
  secret_key = "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"
  region     = var.aws_region
}

# Create security group
resource "aws_security_group" "k8s_cluster_sg" {
  name_prefix = "k8s_cluster_sg"

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 6443
    to_port = 6443
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 2379
    to_port = 2380
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 10250
    to_port = 10250
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "tls_private_key" "mykey" {
  algorithm = "RSA"
  rsa_bits = 2048
}

resource "local_file" "private_key" {
  content  = tls_private_key.mykey.private_key_pem
  filename = "${path.module}/kube.pem"
}

resource "aws_key_pair" "kube" {
  key_name   = "kube"
  public_key = tls_private_key.mykey.public_key_openssh
}

# Launch instances
resource "aws_instance" "k8s_cluster_instances" {
  ami = var.ami_id
  instance_type = var.instance_type
  key_name = aws_key_pair.kube.key_name
  vpc_security_group_ids = [aws_security_group.k8s_cluster_sg.id]

  tags = {
     Name = "master"

  }

}

resource "null_resource" "master" {

provisioner "file" {
    source      = "/root/kube.pem"
    destination = "/home/ubuntu/kube.pem"


    connection {
      type        = "ssh"
      host        = aws_instance.k8s_cluster_instances.public_ip
      user        = "ubuntu"
      private_key = tls_private_key.mykey.private_key_pem
    }
  }
}

resource "null_resource" "master1" {


  # Use SSH connection to provision the instance
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update",
      "sudo hostnamectl set-hostname k8s-master",
      "sudo kubeadm init  > /tmp/kubeadm-init.log",
      "sudo mkdir -p $HOME/.kube",
      "sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      "sudo sh -c 'cat /tmp/kubeadm-init.log | grep -A1 \"kubeadm join\" | tail -n2' > /tmp/join-token.sh",
      "kubectl apply -f https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s.yaml",

    ]
    connection {
      type        = "ssh"
      host        = aws_instance.k8s_cluster_instances.public_ip
      user        = "ubuntu"
      private_key = tls_private_key.mykey.private_key_pem
    }
}
}
resource "null_resource" "copying-join-token" {
  provisioner "local-exec" {
   command = "sudo chmod 600 /root/kube.pem && sleep 120 && scp -o StrictHostKeyChecking=no -i /root/kube.pem ubuntu@${aws_instance.k8s_cluster_instances.public_ip}:/tmp/join-token.sh /root && sudo sed -i '1i#!/bin/bash' /root/join-token.sh && sudo sed -i '2s/^/sudo /' /root/join-token.sh && sleep 60"
  }
 depends_on = [
     aws_instance.k8s_cluster_instances
  ]
}

 data "template_file" "join_token" {
   depends_on = [ null_resource.copying-join-token ]
   #template = file("join-token.sh")
   template = fileexists("join-token.sh") ? file("join-token.sh") : ""
}
# Define the Launch Template
resource "aws_launch_template" "example" {
  name_prefix = "example"
  image_id = "ami-08ff8b7a92e1663d5"
  instance_type = "t2.medium"
  key_name = aws_key_pair.kube.key_name
 # security_group_names = ["All traffic"]
  user_data = base64encode(data.template_file.join_token.rendered)
  depends_on = [
     null_resource.copying-join-token
  ]

}

# Define the Auto Scaling Group
resource "aws_autoscaling_group" "example" {
  name = "example-asg"
  launch_template {
     id = aws_launch_template.example.id
     version = "$Latest"
        }
  vpc_zone_identifier = ["subnet-0573aa1c3ece8e0d4"]
  desired_capacity = 1
  min_size = 1
  max_size = 3
  health_check_grace_period = 300
  health_check_type = "ELB"
  termination_policies = ["OldestInstance", "Default"]

}
# Define the alarm that triggers when CPU or memory usage is above 10%
resource "aws_cloudwatch_metric_alarm" "example" {
  alarm_name          = "example-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "10"
  alarm_description   = "This metric monitors EC2 CPU usage"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }
  alarm_actions       = [aws_autoscaling_policy.example.arn]
}
# Define the scaling policy that adds another instance when the alarm is triggered
resource "aws_autoscaling_policy" "example" {
  name = "example-policy"
  policy_type = "SimpleScaling"
  autoscaling_group_name = aws_autoscaling_group.example.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = 1
  cooldown            = 300
}

