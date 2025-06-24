# devops

We are using [Apple's Pkl](https://github.com/apple/pkl) to manage our configuration files.

## Deploying a release

```
./bin/deploy.rb --app hoa-backend --file ~/code/hoa/hoa-backend/hoa-backend-0.1.4.tar.gz --env development
```

## Generate JSON of configuration

```

./generate-json.rb

```

## Using pkl

```

brew install pkl
pkl eval hoa/config.pkl --format json

```

## Notes

Digital ocean token is expected at
```
~/.digitalocean/token
```

Generate a new one at https://cloud.digitalocean.com/account/api/tokens?i=65dbae
  - we gave it read on droplets and read/update on load balancer

```

Release file hoa-backend-0.1.4.tar.gz copied to 167.99.120.79
Next Steps
~/code/mbryzek/devops/hoa/ssh-backend.sh
rm -rf hoa-backend-0.1.4
tar xfz hoa-backend-0.1.4.tar.gz
mv hoa-backend.log hoa-backend.log.last
cd hoa-backend-0.1.4
../kill.rb hoa-backend
nohup ./run.sh > ../hoa-backend.log &
cd ..
./delete-old-deploys.rb
sleep 1
tail -f hoa-backend.log

# curl localhost:9100/_internal_/healthcheck
```
