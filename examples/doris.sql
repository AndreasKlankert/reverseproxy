CREATE CATALOG mysql_catalog PROPERTIES (
  "type" = "jdbc",
  "user" = "DATABASE_USER",
  "password" = "DATABASE_PASSWORD",
  "jdbc_url" = "jdbc:mysql://mysql.example.com:3306/mydb",
  "driver_url" = "http://nexus-jar-proxy.doris.svc.cluster.local/repository/maven-public/com/mysql/mysql-connector-j/8.3.0/mysql-connector-j-8.3.0.jar",
  "driver_class" = "com.mysql.cj.jdbc.Driver"
);

