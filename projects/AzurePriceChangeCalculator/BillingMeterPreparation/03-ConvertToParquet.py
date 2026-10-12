import pandas as pd

df = pd.read_csv("csv\\ComputeMeters.csv")
df.to_parquet(
    "..\\MasterData\\ComputeMeters.parquet",
    engine="pyarrow",
    compression="snappy",
    index=False
)

df = pd.read_csv("csv\\StorageMeters.csv")
df.to_parquet(
    "..\\MasterData\\StorageMeters.parquet",
    engine="pyarrow",
    compression="snappy",
    index=False
)