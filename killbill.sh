#!/bin/bash -

#Author: The Digital AWS Team
# 

#confirms that executables required for succesful script execution are available
prerequisitecheck()
{
	for prerequisite in basename grep cut aws
	do
		#use of "hash" chosen as it is a shell builtin and will add programs to hash table, possibly speeding execution. Use of type also considered - open to suggestions.
		hash $prerequisite &> /dev/null
		if [[ $? == 1 ]] #has exits with exit status of 70, executable was not found
			then echo "In order to use $app_name, the executable \"$prerequisite\" must be installed." 1>&2 ; exit 70
		fi
	done
}

return_as_initial_maxsize()
{
	if [[ $max_size_change -eq 1 ]]
		then echo "$asg_group_name had its max-size increased temporarily by 1 to a max-size of $asg_temporary_max_size. $app_name will now return the max-size of $asg_group_name to its original max-size of $asg_initial_max_size."
		#decrease max-size by 1
		aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg_group_name" --region $region --max-size=$asg_initial_max_size --profile=$profile
	fi
}

return_as_initial_desiredcapacity()
{
	echo " $app_name will now return the desired-capacity of $asg_group_name to its original desired-capacity of $asg_initial_desired_capacity."
	aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg_group_name" --region $region --desired-capacity=$asg_initial_desired_capacity --profile=$profile
}

wait_for_instance_to_healthy(){
	drain_in_progress=0
	
	while [[ $drain_in_progress -eq 0 ]]
	do
		echo "Cluster Re-Initiating"
		draining_instance_list=($( aws elbv2 describe-target-health --target-group-arn $asg_tgroup --region $region --profile=$profile | jq '.TargetHealthDescriptions[] | select(.TargetHealth.State!="healthy") |.TargetHealth.State' ))
		draining_instance_count=${#draining_instance_list[@]}
		if [ $draining_instance_count -eq 0 ]; then
			drain_in_progress=1
		else 
			drain_in_progress=0
			sleep 60
		fi
	done

}

#set application defaults
app_name="Kill-Bill"
elb_timeout=60
region="us-east-1"
#max_size_change is used as a "flag" to determine if the max-size of an Auto Scaling Group was changed
max_size_change="0"
inservice_time_allowed=1500
inservice_polling_time=60
delimiter="%"

#calls prerequisitecheck function to ensure that all executables required for script execution are available
prerequisitecheck

#handles options processing
while getopts :a:t:r:i:p:l: opt
	do
		case $opt in
			a) asg_group_name="$OPTARG";;
			t) elb_timeout="$OPTARG";;
			r) region="$OPTARG";;
			i) inservice_time_allowed="$OPTARG";;
			p) profile="$OPTARG";;
			l) load_balancer="$OPTARG";;
			*) echo "Error with Options Input. Cause of failure is most likely that an unsupported parameter was passed or a parameter was passed without a corresponding option." 1>&2 ; exit 64 ;;
		esac
	done

#validate elb_timeout is number
##code to be written

if [[ -z $asg_group_name ]]
	then echo "You did not specify an Auto Scaling Group name. In order to use $app_name you must specify an Auto Scaling Group name using -a <autoscalingroupname>." 1>&2 ; exit 64
fi

#region validator
case $region in
	us-east-1|us-west-2|us-west-1|eu-west-1|ca-central-1) ;;
	*) echo "The \"$region\" region does not exist. You must specify a valid region (example: -r us-east-1 or -r us-west-2)." 1>&2 ; exit 64;;
esac

#creates variable containing Auto Scaling Group
asg_result=`aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "$asg_group_name" --region $region --profile=$profile`
#echo "debugging" $asg_result
#validate Auto Scaling Group Exists
asg_arns=$( jq -r '.AutoScalingGroups[] | .AutoScalingGroupARN' <<< "${asg_result}" )
echo "debugging" $asg_arns
#validate - the pipeline of echo -e "$asg_result" | grep -c "AutoScalingGroupARN"  must only return one group found - in the case below - more than one group has been found
if [[ -z "$asg_arns" ]]
	then echo "No Auto Scaling Group was found. Because no Auto Scaling Group has been found, $app_name does not know which Auto Scaling Group should have Instances terminated." 1>&2 ; exit 64
fi
#confirms that certain Auto Scaling processes are not suspended. For certain processes, the "Suspending Processing" state prevents the termination of Auto Scaling Group instances and thus prevents aws-ha-release from running properly.
necessary_processes=()
for process in "${necessary_processes[@]}"
do
	if [[ `echo -e "$asg_result" | grep -c "SuspensionReason"` > 0 ]]
		then echo "Scaling Process $process for the Auto Scaling Group $asg_group_name is currently suspended. $app_name will now exit as Scaling Processes ${necessary_processes[@]} are required for $app_name to run properly." 1>&2 ; exit 77
	fi
done

#gets Auto Scaling Group max-size
#asg_initial_max_size=`echo $asg_result | awk '/MaxSize/{ print $2 }' RS=,`
asg_initial_max_size=$( jq -r '.AutoScalingGroups[] | .MaxSize' <<< "${asg_result}" )
#echo "debugging" $asg_initial_max_size
asg_temporary_max_size=$(($asg_initial_max_size + 1))
#gets Auto Scaling Group desired-capacity
#asg_initial_desired_capacity=`echo $asg_result | awk '/DesiredCapacity/{ print $2 }' RS=,`
asg_initial_desired_capacity=$( jq -r '.AutoScalingGroups[] | .DesiredCapacity' <<< "${asg_result}" )
asg_temporary_desired_capacity=$((asg_initial_desired_capacity + 1))
#gets list of Auto Scaling Group Instances - these Instances will be terminated
asg_instance_list=`echo "$asg_result" | grep InstanceId | sed 's/.*i-/i-/' | sed 's/",//'`

#get the load balancers
asg_elbs[0]="$load_balancer"
#get the target group
asg_tgroup=$( jq -r '.AutoScalingGroups[] | .TargetGroupARNs[0]' <<< "${asg_result}" )

#if the max-size of the Auto Scaling Group is zero there is no reason to run
if [[ $asg_initial_max_size -eq 0 ]]
	then echo "$asg_group_name has a max-size of 0. As the Auto Scaling Group \"$asg_group_name\" has no active Instances there is no reason to run." ; exit 79
fi
#echo a list of Instances that are slated for termination
echo -e "The list of Instances in Auto Scaling Group $asg_group_name that will be terminated is below:\n$asg_instance_list"

as_processes_to_suspend="ReplaceUnhealthy AlarmNotification ScheduledActions AZRebalance"
aws autoscaling suspend-processes --auto-scaling-group-name "$asg_group_name" --scaling-processes $as_processes_to_suspend --region $region --profile=$profile

#if the desired-capacity of an Auto Scaling Group group is greater than or equal to the max-size of an Auto Scaling Group, the max-size must be increased by 1 to cycle instances while maintaining desired-capacity. This is particularly true of groups of 1 instance (where we'd be removing all instances if we cycled).
if [[ $asg_initial_desired_capacity -ge $asg_initial_max_size ]]
	then echo "$asg_group_name has a max-size of $asg_initial_max_size. In order to recycle instances max-size will be temporarily increased by 1 to max-size $asg_temporary_max_size."
	#increase max-size by 1
	aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg_group_name" --region $region --max-size=$asg_temporary_max_size --profile=$profile
	#sets the flag that max-size has been changed
	max_size_change="1"
fi

#increase groups desired capacity to allow for instance recycling without decreasing available instances below initial capacity
echo "$asg_group_name is currently at $asg_initial_desired_capacity desired-capacity. $app_name will increase desired-capacity by 1 to desired-capacity $asg_temporary_desired_capacity."
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg_group_name" --region $region --desired-capacity=$asg_temporary_desired_capacity --profile=$profile

#and begin recycling instances
for instance_selected in $asg_instance_list
do
	all_instances_inservice=0

	#the while loop below sleeps for the auto scaling group to have an InService capacity that is equal to the desired-capacity + 1
	while [[ $all_instances_inservice -eq 0 ]]
	do
		if [[ $inservice_time_taken -gt $inservice_time_allowed ]]
			then echo "During the last $inservice_time_allowed seconds the InService capacity of the $asg_group_name Auto Scaling Group did not meet the Auto Scaling Group's desired capacity of $asg_temporary_desired_capacity." 1>&2
			echo "Because we can't be sure that instances created by this script are healthy, settings that were changed are being left as is. Settings that were changed:"

			if [[ $max_size_change -eq 1 ]]
				then echo "max size was increased by $max_size_change"
			fi

			echo "desired capacity was increased by 1"
			echo "AutoScaling processes \"$as_processes_to_suspend\" were suspended."

			exit 79
		fi

		for index in "${!asg_elbs[@]}"
		do
			inservice_instance_list=$( aws elbv2 describe-target-health --target-group-arn $asg_tgroup --region $region --profile=$profile | jq '.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy") |.TargetHealth.State' )
			inservice_instance_count=`echo "$inservice_instance_list" | wc -l`

			if [ $index -eq 0 ]
				then [ $inservice_instance_count -eq $asg_temporary_desired_capacity ] && all_instances_inservice=1 || all_instances_inservice=0
			else
				[[ ($all_instances_inservice -eq 1) && ($inservice_instance_count -eq $asg_temporary_desired_capacity) ]] && all_instances_inservice=1 || all_instances_inservice=0
			fi
		done

		#sleeps a particular amount of time 
		sleep $inservice_polling_time

		inservice_time_taken=$(($inservice_time_taken+$inservice_polling_time))
		echo $inservice_time_taken " seconds have elapsed . $inservice_instance_count Instances are in Healthy status. $asg_temporary_desired_capacity healthy Instances are required to terminate the next instance."
	#if any status in $elbinstancehealth != "InService" repeat
	done

	################# When the temp istance is up and healthy 
	echo "$asg_group_name has reached a desired-capacity of $asg_temporary_desired_capacity. $app_name can now remove an Instance from service."

	inservice_instance_count=0
	inservice_time_taken=0

	#remove instance from ELB - this ensures no traffic will be directed at an instance that will be terminated
	echo "Instance $instance_selected will now be deregistered from ELBs \"${asg_elbs[@]}.\""
	for elb in "${asg_elbs[@]}"
	do
		aws elbv2 deregister-targets --target-group-arn $asg_tgroup  --targets Id=$instance_selected --region $region --profile=$profile > /dev/null
	done

	# wait for the deristered instance to drain out
###	
###	while[[drain_in_progress -eq 0]]
###	do
###		draining_instance_list=$( aws elbv2 describe-target-health --target-group-arn $asg_tgroup --region $region --profile=$profile | jq '.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy") |.TargetHealth.State' )
	###	draining_instance_count=`echo "$inservice_instance_list" | wc -l`
		### $draining_instance_count -eq $asg_initial_desired_capacity && drain_in_progress=1 || drain_in_progress=0
			
###		sleep $elb_timeout
###	done 


	echo "Deregistration of instance $instance_selected from the group is initiated."
	#sleep for "elb_timeout" seconds so that the instance can complete all processing before being terminated
	sleep $elb_timeout
	#terminates a pre-existing instance within the autoscaling group
	echo "Instance $instance_selected will now be terminated. By terminating this Instance, the actual capacity will be decreased to 1 under desired-capacity."
	aws autoscaling terminate-instance-in-auto-scaling-group --region $region --instance-id $instance_selected --profile=$profile --no-should-decrement-desired-capacity > /dev/null

done

#return temporary desired-capacity to initial desired-capacity
return_as_initial_desiredcapacity

# wait for all instances to come healthy
wait_for_instance_to_healthy

#return max-size to initial size
return_as_initial_maxsize

aws autoscaling resume-processes --auto-scaling-group-name "$asg_group_name" --region $region --profile=$profile

echo "KillBill is done. Cluster is ready to serve"