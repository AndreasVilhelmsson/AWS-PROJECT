#!/bin/bash
STACK_NAME="wp-alb-asg"
echo "Deleting stack $STACK_NAME..."
aws cloudformation delete-stack --stack-name $STACK_NAME
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME
echo "Stack $STACK_NAME deleted!"