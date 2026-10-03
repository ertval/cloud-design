import datetime
from sqlalchemy import Column, Integer, Numeric, DateTime, create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()

class Order(Base):
    __tablename__ = "orders"

    id = Column(Integer, primary_key=True, autoincrement=True)
    # INTEGER, not VARCHAR: the queue payload carries user_id as a string
    # ("20") but it is coerced to int before the insert (see
    # app/validation.py:parse_user_id), so literal SQL such as
    # `SELECT * FROM orders WHERE user_id=20;` works. Must stay in sync with
    # srcs/billing-database/init.sql.
    user_id = Column(Integer, nullable=False)
    number_of_items = Column(Integer, nullable=False)
    # Numeric, not Float: money must not accumulate IEEE-754 rounding drift.
    total_amount = Column(Numeric(12, 2), nullable=False)
    created_at = Column(
        DateTime(timezone=True),
        default=lambda: datetime.datetime.now(datetime.timezone.utc)
    )

    def to_dict(self):
        total = self.total_amount
        return {
            "id": self.id,
            "user_id": self.user_id,
            "number_of_items": self.number_of_items,
            # JSON string carrying the column's own scale ("250.00"): the
            # NUMERIC value reaches the wire with no float rounding, and the
            # string parses back into NUMERIC(12,2) exactly.
            "total_amount": None if total is None else str(total),
            "created_at": self.created_at.isoformat() if self.created_at else None
        }

def get_db_engine(db_url):
    return create_engine(db_url, pool_pre_ping=True)

def init_db(engine):
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine)