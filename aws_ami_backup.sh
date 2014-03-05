#!/bin/bash
# Author: Robert Grignon
# Date: 02/27/2014
#
# $1 - set to daily, weekly, or monthly
#    * If you create a tag in your instance called "AMI_Backup" with a value of
#      "daily, weekly, monthly" the AMI backup will be created and ran at that interval
#
declare -a INSTANCES=($(aws ec2 describe-tags --filters "Name=resource-type,Values=instance" "Name=key,Values=AMI_Backup" "Name=value,Values=$1" --output text | awk '{ print $3 }'))

NUMKEEP=2                               #How many backups should I keep before purging
NAGHOST="admin-03.ae1b.aarp.net"        #Nagios Server (to disable notification)
CURDATE=$(date +%m-%d-%Y)               #Current Data MM-DD-YYYY

echo "Preparing to backup ${INSTANCES[@]}"

#create the images
for i in ${INSTANCES[@]}
do
        CURTIME=$(date +%s)         #Epoch Timestamp

        #Getting the Name of the instance
        NAME=$(aws ec2 describe-tags --filters "Name=resource-type,Values=instance" "Name=resource-id,Values=$i" "Name=key,Values=Name" --output text | awk '{ print $5 }')

        echo "Nagios: Disabled"
        /root/aws_downtime_nagalert.sh ${NAGHOST} stop 2H ${NAME}

        echo "Backing up: $NAME ($i)"
        #create the image
        AMIID=$(aws ec2 create-image --instance-id $i --name "${NAME}_${CURDATE}_${CURTIME}" --description "_${CURTIME}_AMI Backup-$NAME-$i" --output text)

        #wait until the ami has been created so we can get the snapshot id's
        echo -n "Waiting for backup (${AMIID}) to complete"

        while [  $(aws ec2 describe-images --image-ids $AMIID | grep "\"State\":" | awk -F'"' '{ print $4 }') == "pending" ]
        do
                echo -n "."
                sleep 6
        done

        STATUS=$(aws ec2 describe-images --image-ids $AMIID | grep "\"State\":" | awk -F'"' '{ print $4 }')

        case "$STATUS" in
        failed)
                echo "."; echo "Backup: Failed"
        ;;
        available)
                echo "."; echo "Backup: Completed"

                #need to get the snapshot id's so we can tag them
                declare -a TOTAG=($(aws ec2 describe-images --image-ids $AMIID --output text | grep EBS | awk '{ print $3 }'))
                TOTAG+=("$AMIID")

                TAGSTAT=$(aws ec2 create-tags --resources ${TOTAG[@]} --tags Key=Name,Value=$NAME-${CURDATE}_${CURTIME}-Backup --output text)

                if [ $TAGSTAT == "true" ]
                then
                        echo "Create-Tags: Success"
                else
                        echo "Create-Tags: Problem Encountered"
                fi

                #check for older backups
                #Need to do this because I use sed to purge based on row number this makes it less confising for user.
                ((NUMKEEP++))

                declare -a CURBACKUPS=($(aws ec2 describe-images --filters Name=description,Values=*$i* | grep "\"Description\":" | awk -F'_' '{ print $2 }' | sort -r | sed -n "${NUMKEEP},\$p"))

                #deregister old images
                for c in ${CURBACKUPS[@]}
                do
                        DEREGAMI=$(aws ec2 describe-images --filters "Name=description,Values=*$i*" "Name=description,Values=*$c*" | grep "\"ImageId\":" | awk -F'"' '{ print $4 }')

                        #need to get the snapshots before we deregister the ami
                        declare -a DELSNAPS=($(aws ec2 describe-images --image-ids $DEREGAMI --output text | grep EBS | awk '{ print $3 }'))

                        #now we can deregister the ami
                        DEREGSTAT=$(aws ec2 deregister-image --image-id $DEREGAMI --output text)

                        if [ $DEREGSTAT == "true" ]
                        then
                                echo "Deregistered $DEREGAMI: Success"
                        else
                                echo "Deregistered $DEREGAMI: Failed"
                        fi

                        #now we have to delete the snaps
                        for ds in ${DELSNAPS[@]}
                        do
                                DELSNAPSTAT=$(aws ec2 delete-snapshot --snapshot-id $ds --output text)

                                if [ $DELSNAPSTAT == "true" ]
                                then
                                        echo "Delete Snapshot $ds: Success"
                                else
                                        echo "Delete Snapshot $ds: Failed"
                                fi
                        done
                done

        echo "Nagios: Enabled"
        /root/aws_downtime_nagalert.sh ${NAGHOST} start ${NAME}

        ;;
        esac
done
