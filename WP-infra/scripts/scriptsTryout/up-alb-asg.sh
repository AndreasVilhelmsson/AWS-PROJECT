#!/bin/bash
set -e

STACK_NAME="wp-alb-asg"
TEMPLATE="templates/wp-alb-asg-v2.yaml"
PARAMS="params/alb-asg-dev.json"

echo "Validating template..."
aws cloudformation validate-template --template-body file://$TEMPLATE

echo "Creating/Updating stack $STACK_NAME..."
aws cloudformation deploy \
  --stack-name $STACK_NAME \
  --template-file $TEMPLATE \
  --parameter-overrides file://$PARAMS \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM

echo "Stack $STACK_NAME deployed!"