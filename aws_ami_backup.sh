#!/bin/bash
# Author: Robert Grignon
# Date: 02/27/2014
#
# $1 - set to daily, weekly, monthly, or adhoc
#    * If you create a tag in your instance called "AMI_Backup" with a value of
#      "daily, weekly, monthly" the AMI backup will be created and ran at that interval.
#	"adhoc" is used if you wanted to run a manual backup
#
# $2 - (optional) Can pass in the region to overide the default setting
#

APPPATH="/usr/local/bin"
NUMKEEP=2                               #How many backups should I keep before purging
DISMON=1				#Do you want to disable the host before backing it up
NAGHOST="admin-03"        		#Nagios Server (to disable notification)
REGION=${2:-"us-east-1"}		#What region should we search (us-west-2 or us-east-1)
EMAIL=""				#Email Address for notifications
CURDATE=$(date +%m-%d-%Y)               #Current Data MM-DD-YYYY
TEST=0					#If enabled only info will be displayed. Nothing will actually run

#########################

declare -a INSTANCES=($(${APPPATH}/aws ec2 describe-tags --region ${REGION} --filters "Name=resource-type,Values=instance" "Name=key,Values=AMI_Backup" "Name=value,Values=$1" --output text | awk '{ print $3 }'))

echo "Preparing to backup in (${REGION}) ${INSTANCES[@]}"

if [ $TEST -gt 0 ]; then
  echo "Test Mode On - No Changes are taking place"
fi

#create the images
for i in ${INSTANCES[@]}
do
  CURTIME=$(date +%s)         #Epoch Timestamp

  #Getting the Name of the instance
  NAME=$(${APPPATH}/aws ec2 describe-tags --region ${REGION} --filters "Name=resource-type,Values=instance" "Name=resource-id,Values=$i" "Name=key,Values=Name" --output text | awk '{ print $5 }')

  #Extract the domain name. Doing this so we will be able to determine
  #Which AZ or Region the instance belongs to. We will use this to make 
  #sure we call the appropriate nagios server to disable
  DOMAIN=$(echo $NAME | cut -d'.' --complement -f1)
  NAGFQDN=${NAGHOST}.${DOMAIN}
 
  if [ $TEST -gt 0 ]; then
    echo "TESTMODE($i):Instance:      $NAME"
    echo "TESTMODE($i):Domain:        $DOMAIN"
    echo "TESTMODE($i):Nagios Server: $NAGFQDN"
    if [ $DISMON -gt 0 ]; then
      echo "TESTMODE($i):Nagios Plugin: Enabled"
    else 
      echo "TESTMODE($i):Nagios Plugin: Disabled"
    fi
    continue
  else

  if [ $DISMON -gt 0 ]; then
    /usr/local/repos/chef-tools/aws/api-tools/aws_downtime_nagalert.sh ${NAGFQDN} stop 2H ${NAME}
    echo "Nagios: Disabled (aws_downtime_nagalert.sh ${NAGFQDN} stop 2H ${NAME})"
  fi
  
    echo "Backup Start: $NAME ($i) @$(date +%H:%M:%S)"
    #create the image
    AMIID=$(${APPPATH}/aws ec2 create-image --region ${REGION} --instance-id $i --name "${NAME}_${CURDATE}_${CURTIME}" --description "_${CURTIME}_AMI Backup-$NAME-$i" --output text)
  
    #wait until the ami has been created so we can get the snapshot id's
    echo -n "Waiting for backup (${AMIID}) to complete"
  
    while [  $(${APPPATH}/aws ec2 describe-images --region ${REGION} --image-ids $AMIID --output json | grep "\"State\":" | awk -F'"' '{ print $4 }') == "pending" ]
    do
      echo -n "."
      sleep 6
    done
  
    STATUS=$(${APPPATH}/aws ec2 describe-images --region ${REGION} --image-ids $AMIID --output json | grep "\"State\":" | awk -F'"' '{ print $4 }')
  
    case "$STATUS" in
      failed)
        echo "."; echo "Backup: Failed @$(date +%H:%M:%S)"
        RESULT="FAILED"
      ;;
      available)
        echo "."; echo "Backup: Continuing"
  
        #need to get the snapshot id's so we can tag them
        declare -a TOTAG=($(${APPPATH}/aws ec2 describe-images --region ${REGION} --image-ids $AMIID --output json | grep "\"SnapshotId\":" | awk -F'"' '{ print $4 }'))
        TOTAG+=("$AMIID")
  
        TAGSTAT=$(${APPPATH}/aws ec2 create-tags --region ${REGION} --resources ${TOTAG[@]} --tags Key=Name,Value=$NAME-${CURDATE}_${CURTIME}-Backup --output text)
  
        if [ $TAGSTAT == "true" ]
        then
          echo "Create-Tags: Success"
        else
          echo "Create-Tags: Problem Encountered"
        fi
  
        #check for older backups
        #Need to do this because I use sed to purge based on row number this makes it less confising for user.
        ((NUMKEEP++))
  
        declare -a CURBACKUPS=($(${APPPATH}/aws ec2 describe-images --region ${REGION} --filters Name=description,Values=*$i* --output json | grep "\"Description\":" | awk -F'_' '{ print $2 }' | sort -r | sed -n "${NUMKEEP},\$p"))
  
        #deregister old images
        for c in ${CURBACKUPS[@]}
        do
          DEREGAMI=$(${APPPATH}/aws ec2 describe-images --region ${REGION} --filters "Name=description,Values=*$i*" "Name=description,Values=*$c*" --output json | grep "\"ImageId\":" | awk -F'"' '{ print $4 }')
  
          #need to get the snapshots before we deregister the ami
          declare -a DELSNAPS=($(${APPPATH}/aws ec2 describe-images --region ${REGION} --image-ids $DEREGAMI --output text | grep EBS | awk '{ print $3 }'))
  
          #now we can deregister the ami
          DEREGSTAT=$(${APPPATH}/aws ec2 deregister-image --region ${REGION} --image-id $DEREGAMI --output text)
  
          if [ $DEREGSTAT == "true" ]
          then
            echo "Deregistered $DEREGAMI: Success"
          else
            echo "Deregistered $DEREGAMI: Failed"
          fi
  
          #now we have to delete the snaps
          for ds in ${DELSNAPS[@]}
          do
            DELSNAPSTAT=$(${APPPATH}/aws ec2 delete-snapshot --region ${REGION} --snapshot-id $ds --output text)
  
            if [ $DELSNAPSTAT == "true" ]
            then
              echo "Delete Snapshot $ds: Success"
            else
              echo "Delete Snapshot $ds: Failed"
            fi
          done
        done
  
        echo "Backup: Completed @$(date +%H:%M:%S)"
        echo ""
        echo "####################################"
        echo ""
        RESULT="SUCCESS"
      ;;
    esac
  
    if [ $DISMON -gt 0 ]; then
      /usr/local/repos/chef-tools/aws/api-tools/aws_downtime_nagalert.sh ${NAGFQDN} start ${NAME}
      echo "Nagios: Enabled (aws_downtime_nagalert.sh ${NAGFQDN} start ${NAME})"
  
      sleep 3
  
      #setup a new 10min downtime to allow services to come back
      /usr/local/repos/chef-tools/aws/api-tools/aws_downtime_nagalert.sh ${NAGFQDN} stop 30M ${NAME}
    fi
   
    echo "Please check /var/log/ami_backup_${1}.log for additional details" | mail -s "AMI Backup of ${NAME} - ${RESULT}" $EMAIL
  fi
done
