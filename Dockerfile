FROM ruby:alpine

RUN apk add --no-cache git gcc make g++ zlib-dev
WORKDIR /app
COPY . /app/

RUN bundle install -j3
