# AWSのEC2およびEBSリソースを一覧取得し、タブ区切り形式で出力するスクリプト

AWSのcloud shellにて、aws-resource-list.shをアップロード、実行することで取得できます。

デフォルトでは、サブスクライブされている全リージョンに対して実行します。
リージョン名に引数を指定すると、指定したリージョンのみを対象にします。

取得出来るリソース
- EC2
- EBS
- RDS
- S3
