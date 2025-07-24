# より安定したPythonイメージを使用 (alpine は軽量だが、依存関係問題が起きにくい)
FROM python:3.9-slim-buster

# 作業ディレクトリを設定
WORKDIR /app

# 依存関係ファイルをコピー
COPY requirements.txt ./

# 依存関係をインストール
# Gunicorn を追加でインストール
RUN pip install --no-cache-dir -r requirements.txt gunicorn

# アプリケーションコードをコピー
COPY . .

# アプリケーション起動コマンドを Gunicorn + Uvicorn に変更
# Gunicornがuvicornをワーカーとして起動
CMD ["gunicorn", "-w", "4", "-k", "uvicorn.workers.UvicornWorker", "main:app", "--bind", "0.0.0.0:8000"]

# コンテナがポート8000でリッスンすることを公開
EXPOSE 8000