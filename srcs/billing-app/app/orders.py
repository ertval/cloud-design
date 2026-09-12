import datetime
from sqlalchemy import Column, Integer, String, Float, DateTime, create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()

class Order(Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(255), nullable=False)
    number_of_items = Column(Integer, nullable=False)
    total_amount = Column(Float, nullable=False)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "number_of_items": self.number_of_items,
            "total_amount": self.total_amount,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }

def get_db_engine(db_url):
    return create_engine(db_url, pool_pre_ping=True)

def init_db(engine):
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)

