# Installing psql client: https://computingforgeeks.com/install-postgresql-12-on-ubuntu/

sudo apt -y install vim bash-completion wget
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc|sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
echo "deb http://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main" |sudo tee  /etc/apt/sources.list.d/pgdg.list
sudo apt update
sudo apt -y install postgresql-18 postgresql-client-18

apt -y install ruby-rubygems
gem install schema-evolution-manager

# Only if running play apps:
# sudo apt -y upgrade
# sudo apt -y install openjdk-17-jre-headless
