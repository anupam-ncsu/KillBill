![this](killbill.jpg)

Auto Recycle EC2 nodes behind a ASG
## Introduction

In an usecase, we had an application running on EC2 ASG behind a load balancer. To deploy new version of the application, we deployed the app jar through a CI pipeline, then for CD, we manually terminated the instances so that the ASG will rebalance the quorum by spinning up new instances and there-by fetching the new launch template.

In an effort to speedup this orchestration I created Kill Bill


[killbill.sh](./killbill.sh) is a bash script that allows the high-availability / no downtime replacement of all EC2 Instances in an Auto Scaling Group that is behind an Elastic Load Balancer. 
- It delivers a new code version- if your deployment scheme utilizes the termination of EC2 instances in order to release new code KillBill provides an automated way to do this without incurring any downtime.

- It return the ASG to "stable" state - all older EC2 instances can be replaced with newer EC2 instances.


## Directions For Use:
```
# Git Clone the Kill Bill repo.
# Invoke the KillBill script as such: 

killbill.sh -a <ASG-NAME> -l <NLB-NAME> -r <REGION> -p <AWS-PROFILE>
```
the above example would terminate and replace each EC2 Instance in the Auto Scaling group with a new EC2 Instance.

#### Required Options:
``` -a ``` - the name of the Auto Scaling Group for which you wish to perform a high availability release.   
```-l``` - the name of the Load balancer for which you wish to perform a high availability release. Currently we can not query the name of loadbalancer from the ASG.  
```-r``` - allows you specify the region in which your Auto Scaling Group is in. By default aws-ha-release assumes the "us-east-1" region.  
```-p``` - aws profile that you want to assume. The permission to do deployment into any AWS account through the jenkins is configured through profiles. Eg: **dev**

## 

