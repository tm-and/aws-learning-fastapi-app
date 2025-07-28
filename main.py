import os
from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy import create_engine, Column, Integer, String
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.ext.declarative import declarative_base

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
# 4. DI (Dependency Injection) を使ってDBセッションを取得する関数
# ----------------------------------------------------
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ----------------------------------------------------
# 5. APIエンドポイントの定義
# ----------------------------------------------------
@app.get("/")
async def read_root():
    return {"message": "Hello from FastAPI on ECS Fargate with RDS!"}

@app.post("/users/")
async def create_user(username: str, email: str, db: Session = Depends(get_db)):
    db_user = User(username=username, email=email)
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