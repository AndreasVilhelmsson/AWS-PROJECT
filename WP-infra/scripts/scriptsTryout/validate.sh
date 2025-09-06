#!/bin/bash
TEMPLATE=$1
echo "Validating $TEMPLATE..."
aws cloudformation validate-template --template-body file://$TEMPLATE