FROM ruby:alpine

RUN apk add --no-cache git
WORKDIR /app
COPY . /app/

RUN bundle install
