import datetime
from sqlalchemy import Column, Integer, String, Numeric, DateTime, create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()

class Order(Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(String(255), nullable=False)
    number_of_items = Column(Integer, nullable=False)
    # Numeric, not Float: money must not accumulate IEEE-754 rounding drift.
    total_amount = Column(Numeric(12, 2), nullable=False)
    created_at = Column(
        DateTime(timezone=True),
        default=lambda: datetime.datetime.now(datetime.timezone.utc)
    )

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "number_of_items": self.number_of_items,
            "total_amount": float(self.total_amount) if self.total_amount is not None else None,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }

def get_db_engine(db_url):
    return create_engine(db_url, pool_pre_ping=True)

def init_db(engine):
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)