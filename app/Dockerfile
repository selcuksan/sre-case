# 1. asama: kaynagi derle, jar uret
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
# Once sadece pom.xml kopyalanir; kaynak degistiginde bagimliliklar yeniden indirilmesin diye.
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

# 2. asama: sadece jar + Java calisma ortami
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/*.jar app.jar
EXPOSE 8080
# MaxRAMPercentage: heap'i container memory limitinin yuzdesi olarak belirler.
# Sabit -Xmx yazsaydik limit degistiginde image'i yeniden build etmek gerekirdi.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "app.jar"]
