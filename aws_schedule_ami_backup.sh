#!/bin/bash
# Author: Robert Grignon
# Date: 02/27/2014
#
#
declare -a INSTANCE=($(aws ec2 describe-tags --filters "Name=resource-type,Values=instance" "Name=key,Values=Name" "Name=value,Values=${1}" --output text | awk '{ print $3 }'))

case "$2" in

disable)
        TAGSTAT=$(aws ec2 create-tags --resources $INSTANCE --tags Key=AMI_Backup,Value=disabled --output text)

        if [ $TAGSTAT == "true" ]
        then
                exit 1
        else
                echo "I encountered a problem"
                exit 0
        fi
        ;;
daily)
        TAGSTAT=$(aws ec2 create-tags --resources $INSTANCE --tags Key=AMI_Backup,Value=daily --output text)

        if [ $TAGSTAT == "true" ]
        then
                exit 1
        else
                echo "I encountered a problem"
                exit 0
        fi
        ;;
weekly)
        TAGSTAT=$(aws ec2 create-tags --resources $INSTANCE --tags Key=AMI_Backup,Value=weekly --output text)

        if [ $TAGSTAT == "true" ]
        then
                exit 1
        else
                echo "I encountered a problem"
                exit 0
        fi
        ;;
monthly)
        TAGSTAT=$(aws ec2 create-tags --resources $INSTANCE --tags Key=AMI_Backup,Value=monthly --output text)

        if [ $TAGSTAT == "true" ]
        then
                exit 1
        else
                echo "I encountered a problem"
                exit 0
        fi
        ;;
*)
        echo "Unknown Option: $2"
        echo "Usage $0 \$HOST (disable|daily|weekly|monthly)"
        exit 0
        ;;
esac
