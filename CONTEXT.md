# Scry

Scry is a terminal SQL client for querying configured relational databases.

## Language

**Connection profile**:
A named configuration entry containing the information needed to establish a database connection.
_Avoid_: connection config, database config

**Connection**:
A live client session to a database created from a connection profile.
_Avoid_: profile, datasource

**Query execution**:
One request to run an editor buffer or selection against a connection.
_Avoid_: query, command

**Result set**:
The tabular rows returned by one statement in a query execution.
_Avoid_: query result, grid
