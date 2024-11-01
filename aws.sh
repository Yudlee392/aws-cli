#!/bin/bash

# Set region
REGION="us-west-2"

# Tạo VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=fresher-duylnd-cli}]' --output text --query 'Vpc.VpcId')
echo "Created VPC: $VPC_ID"

# Public Subnet AZ1
SUBNET_PUBLIC_AZ1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=fresher-duylnd-public-az1}]' --output text --query 'Subnet.SubnetId')

# Private Subnet AZ1
SUBNET_PRIVATE_AZ1_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone ${REGION}a --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=fresher-duylnd-private-az1}]' --output text --query 'Subnet.SubnetId')

# Public Subnet AZ2
SUBNET_PUBLIC_AZ2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 --availability-zone ${REGION}b --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=fresher-duylnd-public-az2}]' --output text --query 'Subnet.SubnetId')

# Private Subnet AZ2
SUBNET_PRIVATE_AZ2_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 --availability-zone ${REGION}b --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=fresher-duylnd-private-az2}]' --output text --query 'Subnet.SubnetId')

# Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=fresher-duylnd-igw}]' --output text --query 'InternetGateway.InternetGatewayId')
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
echo "Created and attached Internet Gateway: $IGW_ID"

# Public Route Table
PUBLIC_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=fresher-duylnd-public-rt}]' --output text --query 'RouteTable.RouteTableId')
aws ec2 create-route --route-table-id $PUBLIC_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Associate Public Route Table with Public Subnets
aws ec2 associate-route-table --subnet-id $SUBNET_PUBLIC_AZ1_ID --route-table-id $PUBLIC_RT_ID
aws ec2 associate-route-table --subnet-id $SUBNET_PUBLIC_AZ2_ID --route-table-id $PUBLIC_RT_ID

# Private Route Table
PRIVATE_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=fresher-duylnd-private-rt}]' --output text --query 'RouteTable.RouteTableId')

# Associate Private Route Table with Private Subnets
aws ec2 associate-route-table --subnet-id $SUBNET_PRIVATE_AZ1_ID --route-table-id $PRIVATE_RT_ID
aws ec2 associate-route-table --subnet-id $SUBNET_PRIVATE_AZ2_ID --route-table-id $PRIVATE_RT_ID
echo "Configured route tables and associations"

# Security Group for NAT Instance
NAT_SG_ID=$(aws ec2 create-security-group --group-name fresher-duylnd-nat-sg --description "Security Group for NAT instance" --vpc-id $VPC_ID --output text --query 'GroupId')
aws ec2 authorize-security-group-ingress --group-id $NAT_SG_ID --protocol tcp --port 22 --cidr 14.176.232.122/32
aws ec2 authorize-security-group-ingress --group-id $NAT_SG_ID --protocol -1 --cidr 10.0.0.0/16

# Security Group for ALB
ALB_SG_ID=$(aws ec2 create-security-group --group-name fresher-duylnd-alb-sg --description "Security Group for ALB" --vpc-id $VPC_ID --output text --query 'GroupId')
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 80 --cidr 14.176.232.122/32
aws ec2 authorize-security-group-ingress --group-id $ALB_SG_ID --protocol tcp --port 443 --cidr 14.176.232.122/32

# Security Group for ECS Server Instances
SERVER_SG_ID=$(aws ec2 create-security-group --group-name fresher-duylnd-server-sg --description "Security Group for server instances" --vpc-id $VPC_ID --output text --query 'GroupId')
aws ec2 authorize-security-group-ingress --group-id $SERVER_SG_ID --protocol -1 --cidr 10.0.0.0/24
aws ec2 authorize-security-group-ingress --group-id $SERVER_SG_ID --protocol tcp --port 80 --source-group $ALB_SG_ID
aws ec2 authorize-security-group-ingress --group-id $SERVER_SG_ID --protocol tcp --port 443 --source-group $ALB_SG_ID

echo "Configured security groups"

# NAT Instance
AMI_ID=$(aws ec2 describe-images --region $REGION --owners amazon --filters "Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2" --query 'Images[0].ImageId' --output text)
NAT_INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t2.nano --subnet-id $SUBNET_PUBLIC_AZ1_ID --associate-public-ip-address --security-group-ids $NAT_SG_ID --output text --query 'Instances[0].InstanceId' --user-data '#!/bin/bash
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE')
aws ec2 modify-instance-attribute --instance-id $NAT_INSTANCE_ID --source-dest-check "{\"Value\": false}"
aws ec2 create-route --route-table-id $PRIVATE_RT_ID --destination-cidr-block 0.0.0.0/0 --instance-id $NAT_INSTANCE_ID
echo "Created NAT Instance: $NAT_INSTANCE_ID"

# Allocate and Associate Elastic IP for NAT Instance
EIP_ALLOCATION_ID=$(aws ec2 allocate-address --domain vpc --output text --query 'AllocationId')
aws ec2 associate-address --instance-id $NAT_INSTANCE_ID --allocation-id $EIP_ALLOCATION_ID
echo "Elastic IP allocated and associated with NAT Instance"

# Load Balancer and Target Group
ALB_ARN=$(aws elbv2 create-load-balancer --name fresher-duylnd-alb --subnets $SUBNET_PUBLIC_AZ1_ID $SUBNET_PUBLIC_AZ2_ID --security-groups $ALB_SG_ID --scheme internet-facing --type application --output text --query 'LoadBalancers[0].LoadBalancerArn')
TARGET_GROUP_ARN=$(aws elbv2 create-target-group --name fresher-duylnd-tg --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type ip --health-check-path "/healthcheck.html" --health-check-protocol HTTP --health-check-interval-seconds 30 --health-check-timeout-seconds 5 --healthy-threshold-count 3 --unhealthy-threshold-count 3 --output text --query 'TargetGroups[0].TargetGroupArn')

# Listeners for ALB
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=redirect,RedirectConfig="{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}"
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTPS --port 443 --ssl-policy ELBSecurityPolicy-2016-08 --certificates CertificateArn=arn:aws:acm:us-west-2:257394455086:certificate/69f7dd38-5717-4130-a930-0f10ff74cf83 --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN
echo "Listeners for ALB created"

# ECS Cluster and Service
CLUSTER_ARN=$(aws ecs create-cluster --cluster-name sv-cli --output text --query 'cluster.clusterArn')

# Tạo CloudWatch Log Group cho MySQL
aws logs create-log-group --log-group-name /ecs/fresher-duylnd/mysql
aws logs put-retention-policy --log-group-name /ecs/fresher-duylnd/mysql --retention-in-days 1

# Tạo CloudWatch Log Group cho Server
aws logs create-log-group --log-group-name /ecs/fresher-duylnd
aws logs put-retention-policy --log-group-name /ecs/fresher-duylnd --retention-in-days 1

# IAM Role for ECS Task Execution
aws iam attach-role-policy --role-name ecsTaskExecutionRole --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Task Definition (with external JSON for container details)
TASK_DEF=$(aws ecs register-task-definition \
  --family fresher-duylnd-task \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 1024 \
  --memory 1024 \
  --execution-role-arn arn:aws:iam::257394455086:role/ecsTaskExecutionRole \
  --task-role-arn arn:aws:iam::257394455086:role/ecsTaskExecutionRole \
  --container-definitions '[{
      "name": "nginx",
      "image": "257394455086.dkr.ecr.us-west-2.amazonaws.com/server:latest",
      "cpu": 512,
      "memory": 512,
      "essential": true,
      "portMappings": [{
          "containerPort": 80,
          "protocol": "tcp"
      }],
      "environment": [
          { "name": "MYSQL_SERVER", "value": "0.0.0.0" },
          { "name": "MYSQL_DATABASE", "value": "mysql" },
          { "name": "MYSQL_USER", "value": "test" },
          { "name": "MYSQL_PASSWORD", "value": "123456" }
      ],
      "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
              "awslogs-group": "/ecs/fresher-duylnd",
              "awslogs-region": "us-west-2",
              "awslogs-stream-prefix": "ecs",
              "awslogs-create-group": "true"
          }
      }
  },{
      "name": "mysql",
      "image": "257394455086.dkr.ecr.us-west-2.amazonaws.com/mysql:latest",
      "cpu": 512,
      "memory": 512,
      "essential": true,
      "portMappings": [{
          "containerPort": 3306,
          "protocol": "tcp"
      }],
      "environment": [
          { "name": "MYSQL_ROOT_PASSWORD", "value": "123456" },
          { "name": "MYSQL_DATABASE", "value": "mysql" },
          { "name": "MYSQL_USER", "value": "test" },
          { "name": "MYSQL_PASSWORD", "value": "123456" }
      ],
      "logConfiguration": {
          "logDriver": "awslogs",
          "options": {
              "awslogs-group": "/ecs/fresher-duylnd/mysql",
              "awslogs-region": "us-west-2",
              "awslogs-stream-prefix": "ecs",
              "awslogs-create-group": "true"
          }
      }
  }]' \
  --output text --query 'taskDefinition.taskDefinitionArn')


aws ecs create-service --cluster $CLUSTER_ARN --service-name fresher-duylnd-service --task-definition $TASK_DEF --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_PRIVATE_AZ1_ID,$SUBNET_PRIVATE_AZ2_ID],securityGroups=[$SERVER_SG_ID],assignPublicIp=DISABLED}" \
    --load-balancers "targetGroupArn=$TARGET_GROUP_ARN,containerName=nginx,containerPort=80" --deployment-controller type=ECS \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" \
    --tags key=Name,value=fresher-duylnd-service
echo "ECS Cluster and Service created"

