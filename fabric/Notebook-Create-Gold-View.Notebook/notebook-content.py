# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "379d26e0-b400-4dee-a78d-74787c6365f1",
# META       "default_lakehouse_name": "Lakehouse_Sketch",
# META       "default_lakehouse_workspace_id": "8fa0502b-dfda-492f-8898-98142d909ba6",
# META       "known_lakehouses": [
# META         {
# META           "id": "379d26e0-b400-4dee-a78d-74787c6365f1"
# META         }
# META       ]
# META     }
# META   }
# META }

# CELL ********************

# Welcome to your new notebook
# Type here in the cell editor to add code!

df = spark.sql('''SELECT 
CallType 
, ServiceLine, Handler, TimeOnCall_minutes, CallerID, CallStarted FROM Lakehouse_Sketch.dbo.calls limit 5''')
display(df)

df = spark.sql("SELECT * FROM Lakehouse_Sketch.dbo.calls limit 5")
display(df)

exclude = {"Satisfaction"}
df2 = df.select(*[c for c in df.columns if c not in exclude])
display(df2)
df3 = df.drop(*exclude)
display(df3)

include = ["CallType", "ServiceLine", "Handler", "TimeOnCall_minutes", "CallerID"]
df4 = df.select(*include)
display(df4)


# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

df = spark.sql("SELECT * FROM Lakehouse_Sketch.dbo.calls")
display(df)

df.write.format("delta").mode("overwrite").saveAsTable("dbo.CallsFromNotebook")

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }
