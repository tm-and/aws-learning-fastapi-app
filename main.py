import os
from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy import create_engine, Column, Integer, String
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.ext.declarative import declarative_base
from pydantic import BaseModel

# ----------------------------------------------------
# 1. データベース接続設定
# ----------------------------------------------------

# Secrets Managerから環境変数として渡されるDB接続情報を取得
DATABASE_USER = os.environ.get("DATABASE_USER")
DATABASE_PASSWORD = os.environ.get("DATABASE_PASSWORD")
DATABASE_HOST = os.environ.get("DATABASE_HOST")
DATABASE_PORT = os.environ.get("DATABASE_PORT")
DATABASE_NAME = os.environ.get("DATABASE_NAME")

# データベース接続URLを構築
DATABASE_URL = f"postgresql://{DATABASE_USER}:{DATABASE_PASSWORD}@{DATABASE_HOST}:{DATABASE_PORT}/{DATABASE_NAME}"

# SQLAlchemyのエンジンを作成
engine = create_engine(DATABASE_URL)

# セッションを作成するためのクラスを定義
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# データベースモデルのベースクラスを定義
Base = declarative_base()

# ----------------------------------------------------
# 2. データベースモデル定義
# (db_setup.py と同じ User モデル定義をここに置くことで、アプリがDBを理解できる)
# ----------------------------------------------------
class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True)
    email = Column(String, unique=True, index=True)


# ----------------------------------------------------
# 3. FastAPIアプリケーションの定義
# ----------------------------------------------------
app = FastAPI()

# ----------------------------------------------------
# 4. Pydanticモデル定義 (リクエストボディの型)
# ----------------------------------------------------
class UserCreate(BaseModel):
    username: str
    email: str

# ----------------------------------------------------
# 5. DI (Dependency Injection) を使ってDBセッションを取得する関数
# ----------------------------------------------------
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ----------------------------------------------------
# 6. APIエンドポイントの定義
# ★create_user エンドポイントを修正★
# ----------------------------------------------------
@app.get("/")
async def read_root():
    return {"message": "Hello from FastAPI on ECS Fargate with RDS!"}

# 引数を UserCreate モデルのインスタンスとして受け取る
@app.post("/users/")
async def create_user(user: UserCreate, db: Session = Depends(get_db)): # ★引数を修正★
    db_user = User(username=user.username, email=user.email) # ★参照方法を修正★
    db.add(db_user)
    db.commit()
    db.refresh(db_user)
    return db_user

@app.get("/users/")
async def read_users(skip: int = 0, limit: int = 100, db: Session = Depends(get_db)):
    users = db.query(User).offset(skip).limit(limit).all()
    return users

# Uvicorn サーバーの起動ロジック (通常は Dockerfile の CMD で実行されるため、コメントアウトでもOK)
# if __name__ == "__main__":
#     import uvicorn
#     PORT = int(os.environ.get("PORT", 8000))
#     uvicorn.run(app, host="0.0.0.0", port=PORT)