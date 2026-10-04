# 開発メモ

## 社内プロキシ (TLS 中継) のある環境

HTTPS が中継されていると、コンテナ内の `curl` や `git clone` が証明書エラーで失敗します。
プロキシの CA 証明書を `~/.zscaler/certs.pem` に置いておくと、`make images` がそれを `certs.pem` にコピーし、
BuildKit の secret (`--secret id=ca_cert,src=certs.pem`) としてダウンロード処理にだけ渡します。
証明書はイメージのレイヤには残りません。`~/.zscaler/certs.pem` が無ければ空の `certs.pem` が作られ、CA の追加はスキップされます。

別の場所の証明書を使う場合:

```bash
make images CA_CERT=/path/to/ca.pem
```

`certs.pem` は git 管理外です。
