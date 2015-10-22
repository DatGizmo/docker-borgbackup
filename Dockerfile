FROM debian:jessie

MAINTAINER Silvio Fricke <silvio.fricke@gmail.com>

VOLUME /B /backupdir
WORKDIR /borg

ENTRYPOINT ["/usr/bin/borgctrl"]
CMD ["--help"]

# to prevent some filepath issues with python code we have to set the language
ENV LANG C.UTF-8
RUN ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update -y \
    && apt-get install -y \
        build-essential \
        fuse \
        git-core \
        libacl1-dev \
        libfuse-dev \
        liblz4-dev \
        liblzma-dev \
        libssl-dev \
        openssh-server \
        pkg-config \
        python-lz4 \
        python-virtualenv \
        python3-dev \
    && apt-get clean -y

ADD misc/shini/shini.sh /usr/bin/shini
RUN chmod a+x /usr/bin/shini

RUN virtualenv --python=python3 /borg-env ; \
    . /borg-env/bin/activate ; \
    pip -v --log=/pip-install.log install --upgrade pip ; \
    pip -v --log=/pip-install.log install cython ; \
    pip -v --log=/pip-install.log install tox

# the "git clone" and "pip install" is cached, we need to invalidate the docker cache here
#ADD http://www.random.org/strings/?num=1&len=10&digits=on&upperalpha=on&loweralpha=on&unique=on&format=plain&rnd=new uuid

# borg - "stable" version
#RUN . /borg-env/bin/activate ;\
#    pip install borgbackup

# borg - development version uncomment the 2 lines above to use the development
# version of borgbackup
ENV VERSION=0.27.0
RUN git clone https://github.com/borgbackup/borg.git /borgbackup-git -b ${VERSION}; \
    . /borg-env/bin/activate ; \
    pip -v --log=/pip-install.log install 'llfuse<0.41' ;\
    pip -v --log=/pip-install.log install -r /borgbackup-git/requirements.d/development.txt ;\
    pip -v --log=/pip-install.log install -e /borgbackup-git
# borgweb is a webbased userinterface for borgbackup, maybe its usefull in
# future, but for now its commented and not tested
#    git clone https://github.com/borgbackup/borgweb.git borgweb-git -b master; \
#    pip install -e borgweb-git
#    EXPOSE 7000

ADD adds/borgctrl.sh /usr/bin/borgctrl
RUN chmod a+x /usr/bin/borgctrl ;\
    mkdir -p /REPO ;\
    rm -rf /etc/ld.so.cache

