This script outputs a list of AWS resources in CSV format.
The following resources are output.
- EC2 instances
- EBS volumes
- RDS instances
- S3 buckets

The output file is compressed in a zip file.
The output file name is "resource_list_<accountid>_<date>.zip".


# AWSのEC2およびEBSリソースを一覧取得し、タブ区切り形式で出力するスクリプト

AWS CloudShellでaws-resource-list.shをアップロードして実行することで取得できます。

デフォルトでは、サブスクライブされている全リージョンで実行します。
リージョン名を引数に指定すると、そのリージョンのみを対象にします。

取得出来るリソース
- EC2
- EBS
- RDS
- S3

## 使用方法

### 全リージョンで実行
```sh
sh ./aws-resource-list.sh
```

### 特定のリージョン（例:東京リージョン）で実行
```sh
sh ./aws-resource-list.sh ap-northeast-1
```

### バージョンを表示
```sh
sh ./aws-resource-list.sh --version
```