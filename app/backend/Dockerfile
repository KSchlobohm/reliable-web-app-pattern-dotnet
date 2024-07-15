FROM tiangolo/uwsgi-nginx-flask:python3.11

# setup ssh
ENV SSH_PASSWD "root:Docker!"
RUN apt-get update \
        && apt-get install -y --no-install-recommends dialog \
        && apt-get update \
        && apt-get install -y --no-install-recommends openssh-server \
        && echo "$SSH_PASSWD" | chpasswd 
COPY sshd_config /etc/ssh/
COPY init.sh /usr/local/bin/

# add code
RUN mkdir /code
WORKDIR /code
ADD requirements.txt /code/
RUN pip install -r requirements.txt --no-cache-dir
ADD . /code/
        
RUN chmod u+x /usr/local/bin/init.sh
EXPOSE 8000 2222

ENTRYPOINT ["init.sh"]