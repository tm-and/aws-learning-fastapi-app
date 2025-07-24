from fastapi import FastAPI
import os

app = FastAPI()

@app.get("/")
async def read_root():
    return {"message": "Hello from FastAPI on ECS Fargate!"}

@app.get("/items/{item_id}")
async def read_item(item_id: int, q: str = None):
    return {"item_id": item_id, "q": q}

# 環境変数からポート番号を取得（ECS/Fargateで指定されるポートに合わせる）
# コンテナ内ではPORT環境変数が設定されることが多い
PORT = int(os.environ.get("PORT", 8000))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=PORT)
