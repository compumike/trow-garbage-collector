FROM ruby:3.0.0-alpine AS build

ENV GEM_HOME="/usr/local/bundle"
ENV PATH $GEM_HOME/bin:$GEM_HOME/gems/bin:$PATH
RUN echo "gem: --no-document" > ~/.gemrc

#RUN apk add --no-cache \
#  build-base \
#  ruby-dev

COPY Gemfile Gemfile.lock /app/
WORKDIR /app/
RUN bundle install --jobs 16 --retry 5

# Comment out these four lines for development convenience.
# Uncomment for a smaller container image.
#FROM ruby:3.0.0-alpine AS run
#COPY --from=build $GEM_HOME $GEM_HOME
#COPY Gemfile Gemfile.lock /app/
#WORKDIR /app/

RUN wget -O /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(wget -q -O - https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl && chmod a+x /usr/local/bin/kubectl

COPY ./src/ /app/src/

# Set HOME so kubectl runs
ENV HOME=/app

CMD ["/app/src/main.rb"]
