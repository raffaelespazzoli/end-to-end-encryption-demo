#customer
cd customer/java/springboot
mvn clean package
docker build -t quay.io/raffaelespazzoli/e2e-encryption-tutorial-customer:v1 .
docker push quay.io/raffaelespazzoli/e2e-encryption-tutorial-customer:v1

#preference
cd ../../../preference/java/springboot
mvn clean package
docker build -t quay.io/raffaelespazzoli/e2e-encryption-tutorial-preference:v1 .
docker push quay.io/raffaelespazzoli/e2e-encryption-tutorial-preference:v1

#recommendation
cd ../../../recommendation/java/springboot
mvn clean package
docker build -t quay.io/raffaelespazzoli/e2e-encryption-tutorial-recommendation:v1 .
docker push quay.io/raffaelespazzoli/e2e-encryption-tutorial-recommendation:v1