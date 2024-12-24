#!/bin/bash

# Description
# This script outputs a list of AWS resources in CSV format.
# The following resources are output.
# - EC2 instances
# - EBS volumes
# - RDS instances
# - S3 buckets
# The output file is compressed in a zip file.
# The output file name is "resource_list_<accountid>_<date>.zip".

# Variables
VERSION="0.7.1" # version
accountid=($(aws sts get-caller-identity --query 'Account' --output text))
date=$(TZ=Asia/Tokyo date -d "yesterday" '+%Y-%m-%d')

outputfolder=resource_list_${accountid}_$(TZ=Asia/Tokyo date '+%Y%m%d_%H%M%S')
temp_ec2file=${outputfolder}/temp_ec2.txt
temp_ebsfile=${outputfolder}/temp_ebs.txt
temp_s3file=${outputfolder}/temp_s3.txt
output_ec2file=${outputfolder}/list_ec2.csv
output_ebsfile=${outputfolder}/list_ebs.csv
output_rdsfile=${outputfolder}/list_rds.csv
output_s3file=${outputfolder}/list_s3.csv

# If the version option is specified, output the version information and exit
if [[ "$1" == "--version" ]]; then
    echo "AWS Resource List Script, version $VERSION"
    exit 0
fi

# If arguments are set, set regions to the arguments
if [ "$#" -gt 0 ]; then
    regions=("$@")
else
    # All Regions
    regions=($(aws ec2 describe-regions --query Regions[*].RegionName --output text))
fi
echo "■Target Regions: ${regions[@]}"
total_regions=${#regions[@]}


# Create output folder
mkdir -p ${outputfolder}

# Progress bar display function
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local progress=$((current * width / total))
    local percent=$((current * 100 / total))
    local remaining=$((width - progress))
    if [ $remaining -lt 0 ]; then
        remaining=0
    fi

    if [ $current -eq $total ]; then
        printf "\r["
        printf "%0.s#" $(seq 1 $width)
        printf "] 100%%"
    else
        printf "\r["
        printf "%0.s#" $(seq 1 $progress)
        printf "%0.s-" $(seq 1 $remaining)
        printf "] %d%%" $percent
    fi
}

# EC2
echo "# EC2 information acquisition"
for ((i = 0; i < total_regions; i++)); do
    region=${regions[$i]}
    show_progress $((i + 1)) $total_regions

    aws ec2 describe-instances --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value | [0], State.Name, InstanceType, PlatformDetails, Placement.AvailabilityZone, BlockDeviceMappings[0].Ebs.VolumeId]' --output json --region ${region} | jq -r '.[][] | @tsv' >>./${temp_ec2file}
done
sort -t $'\t' -k 6 ./${temp_ec2file} -o ./${temp_ec2file}
echo ""

# EBS
echo "# EBS information acquisition"
for ((i = 0; i < total_regions; i++)); do
    region=${regions[$i]}
    show_progress $((i + 1)) $total_regions

    aws ec2 describe-volumes --query 'Volumes[*].[VolumeId, Size, VolumeType, AvailabilityZone]' --output json --region ${region} | jq -r '.[] | @tsv' >>./${temp_ebsfile}
done

sort -t $'\t' -k 1 ./${temp_ebsfile} -o ./${temp_ebsfile}
echo ""

# Merge EC2 and EBS Information
echo "InstancsName,State,InstanceType,PlatformDetails,AvailabilityZone,Size,VolumeType,VolumeId" >>./${output_ec2file}
## Outer join (left)
join -t $'\t' -a 1 -1 6 -2 1 ./${temp_ec2file} ./${temp_ebsfile} | awk -F $'\t' '{print $2 "," $3 "," $4 "," $5 "," $6 "," $7 "," $8 "," $1}' >>./${output_ec2file}

## Output unmatched lines = Extended volumes
echo "VolumeId,Size,VolumeType,AvailabilityZone" >>./${output_ebsfile}
join -t $'\t' -v 2 -1 6 -2 1 ./${temp_ec2file} ./${temp_ebsfile} | awk -F $'\t' '{print $1 "," $2 "," $3 "," $4}' >>./${output_ebsfile}

# RDS
echo "# RDS information acquisition"

echo "DBInstanceIdentifier, DBInstanceStatus, DBInstanceClass, Engine, EngineVersion, AvailabilityZone, MultiAZ, StorageType, AllocatedStorage" >>./${output_rdsfile}
for ((i = 0; i < total_regions; i++)); do
    region=${regions[$i]}
    show_progress $((i + 1)) $total_regions
    aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier, DBInstanceStatus, DBInstanceClass, Engine, EngineVersion, AvailabilityZone, MultiAZ, StorageType, AllocatedStorage]' --output text --region ${region} | sed -e 's/\t/,/g' >>./${output_rdsfile}
done
echo ""

# S3
echo "# S3 information acquisition"
echo "BucketName,Region,Date,Size(Bytes)" >>./${output_s3file}
aws s3 ls >./${temp_s3file}
total_buckets=$(awk '{print $3}' "./${temp_s3file}" | wc -l)
current_bucket=0

# Loop through the number of S3 buckets
awk '{print $3}' "./${temp_s3file}" | while read bucket_name; do
    # progress bar
    current_bucket=$((current_bucket + 1))
    show_progress $current_bucket $total_buckets

    # Get the region name of the S3 bucket
    region=$(aws s3api get-bucket-location --bucket "$bucket_name" --query 'LocationConstraint' --output text)
    if [ "$region" == "None" ]; then
        region="ap-northeast-1"
    fi

    # Skip if the region is not in the target regions
    if [[ ! " ${regions[@]} " =~ " ${region} " ]]; then
        continue
    fi

    # Get metrics from CloudWatch
    metrics=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/S3 \
        --metric-name BucketSizeBytes \
        --dimensions \
        Name=StorageType,Value=StandardStorage \
        Name=BucketName,Value="$bucket_name" \
        --statistics Maximum \
        --start-time "${date}T00:00:00Z" \
        --end-time "${date}T23:59:59Z" \
        --period 86400 \
        --unit Bytes \
        --region "$region" |
        jq -r --arg bucket_name "$bucket_name" --arg region "$region" '
            .Datapoints
            | sort_by(.Timestamp)
            | .[]
            | [$bucket_name, $region, (.Timestamp|strptime("%Y-%m-%dT%H:%M:%S%z")|strftime("%Y/%m/%d")), (.Maximum | floor)]
            | join(",")
        ')

    # If metrics are empty, output only the bucket name and region to the CSV
    if [ -z "$metrics" ]; then
        echo "$bucket_name,$region,," >>"${output_s3file}"
    else
        echo "$metrics" >>"${output_s3file}"
    fi
done
echo ""

# Clean up temporary files
#rm ./${temp_ec2file}
#rm ./${temp_ebsfile}
#rm ./${temp_s3file}

# Zip the output folder
zip -r ${outputfolder}.zip ${outputfolder}

echo "Output file: ${outputfolder}.zip"
echo "Done."
# End of script