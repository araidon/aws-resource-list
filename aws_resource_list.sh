#!/bin/bash
# 各種変数
VERSION="0.7.0" # version
accountid=($(aws sts get-caller-identity --query 'Account' --output text))
date=$(TZ=Asia/Tokyo date -d "yesterday" '+%Y-%m-%d')
outputfilename=resource_list_${accountid}_$(TZ=Asia/Tokyo date '+%Y%m%d_%H%M%S').csv
temp_ec2file=list_ec2.txt
temp_ebsfile=list_ebs.txt
temp_s3file=list_s3.txt

# versionオプションが指定された場合、バージョン情報を出力して終了
if [[ "$1" == "--version" ]]; then
    echo "AWS Resource List Script, version $VERSION"
    exit 0
fi

# 引数が設定されていたら、regionsを引数に設定
if [ "$#" -gt 0 ]; then
    regions=("$@")
else
    # All Regions
    regions=($(aws ec2 describe-regions --query Regions[*].RegionName --output text))
fi
echo "■対象リージョン: ${regions[@]}"
total_regions=${#regions[@]}

# Outputファイルの初期化
echo -n > ${outputfilename}

# プログレスバー表示関数
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
echo "■EC2 一覧取得中" 
for ((i=0; i<total_regions; i++)); do
    region=${regions[$i]}
    show_progress $((i+1)) $total_regions

    aws ec2 describe-instances --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value | [0], State.Name, InstanceType, PlatformDetails, Placement.AvailabilityZone, BlockDeviceMappings[0].Ebs.VolumeId]' --output json --region ${region} | jq -r '.[][] | @tsv' >> ./${temp_ec2file}

done
sort -t $'\t' -k 6 ./${temp_ec2file} -o ./${temp_ec2file}
echo ""

# EBS
echo "■EBS 一覧取得中" 
for ((i=0; i<total_regions; i++)); do
    region=${regions[$i]}
    show_progress $((i+1)) $total_regions

    aws ec2 describe-volumes --query 'Volumes[*].[VolumeId, Size, VolumeType, AvailabilityZone]' --output json --region ${region} | jq -r '.[] | @tsv' >> ./${temp_ebsfile}
done

sort -t $'\t' -k 1 ./${temp_ebsfile} -o ./${temp_ebsfile}
echo ""

# EC2とEBSをマージ 
echo "# EC2" >> ./${outputfilename}
echo "InstancsName,State,InstanceType,PlatformDetails,AvailabilityZone,Size,VolumeType,VolumeId" >> ./${outputfilename}
## 外部結合(左)
join -t $'\t' -a 1 -1 6 -2 1 ./${temp_ec2file} ./${temp_ebsfile} | awk -F $'\t' '{print $2 "," $3 "," $4 "," $5 "," $6 "," $7 "," $8 "," $1}' >> ./${outputfilename}
echo ""  >> ./${outputfilename}

## 一致しない行を出力 = 拡張ボリューム
echo "# Non-root-Volumes of EBS" >> ./${outputfilename}
echo "VolumeId,Size,VolumeType,AvailabilityZone" >> ./${outputfilename}
join -t $'\t' -v 2 -1 6 -2 1 ./${temp_ec2file} ./${temp_ebsfile} | awk -F $'\t' '{print $1 "," $2 "," $3 "," $4}' >> ./${outputfilename}
echo ""  >> ./${outputfilename}

# RDS
echo "■RDS 一覧取得中" 
echo "# RDS"  >> ./${outputfilename}
echo "DBInstanceIdentifier, DBInstanceStatus, DBInstanceClass, Engine, EngineVersion, AvailabilityZone, MultiAZ, StorageType, AllocatedStorage" >> ./${outputfilename}
for ((i=0; i<total_regions; i++)); do
    region=${regions[$i]}
    show_progress $((i+1)) $total_regions
	aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier, DBInstanceStatus, DBInstanceClass, Engine, EngineVersion, AvailabilityZone, MultiAZ, StorageType, AllocatedStorage]' --output text --region ${region} | sed -e 's/\t/,/g' >> ./${outputfilename}
done
echo ""  | tee -a ${outputfilename}

# S3
echo "■S3 一覧取得中" 
echo "# S3"  >> ./${outputfilename}
echo "BucketName,Region,Date,Size(Bytes)" >> ./${outputfilename}
aws s3 ls > ./${temp_s3file}
total_buckets=$(awk '{print $3}' "./${temp_s3file}" | wc -l)
current_bucket=0

# S3バケット数でループ
awk '{print $3}' "./${temp_s3file}" | while read bucket_name; do
    # progress bar
    current_bucket=$((current_bucket + 1))
    show_progress $current_bucket $total_buckets

	# S3バケットのリージョン名を取得
    region=$(aws s3api get-bucket-location --bucket "$bucket_name" --query 'LocationConstraint' --output text)
    if [ "$region" == "None" ]; then
        region="ap-northeast-1"
    fi

    # リージョンが対象リージョンに含まれていない場合はskip
    if [[ ! " ${regions[@]} " =~ " ${region} " ]]; then
        continue
    fi

    # CloudWatchからメトリクスを取得
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
        --region "$region" \
        | jq -r --arg bucket_name "$bucket_name" --arg region "$region" '
            .Datapoints
            | sort_by(.Timestamp)
            | .[]
            | [$bucket_name, $region, (.Timestamp|strptime("%Y-%m-%dT%H:%M:%S%z")|strftime("%Y/%m/%d")), (.Maximum | floor)]
            | join(",")
        ')

    # メトリクスが空の場合、バケット名とリージョン名だけをCSVに出力
    if [ -z "$metrics" ]; then
        echo "$bucket_name,$region,," >> "${outputfilename}"
    else
        echo "$metrics" >> "${outputfilename}"
    fi
done
echo ""

# 一時ファイルの整理 
rm ./${temp_ec2file}
rm ./${temp_ebsfile}
rm ./${temp_s3file}

