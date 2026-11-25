# CPLogger 自体の Windows サービス登録は、子プロセス方式への変更に伴い廃止しました。
[CmdletBinding()]
param()

throw 'Install-Service.ps1 は旧単独サービス方式のスクリプトです。CPLogger 自体はサービス登録しません。既存の親サービスに組み込む場合は Prepare-ChildProcess.ps1、確認用親サービスを登録する場合は Install-TestParentService.ps1 を実行してください。旧 CPLogger サービスの移行には各スクリプトの -MigrateLegacyService を指定してください。'