# The marketing site: static files behind nginx. Railway builds this when
# the service's root directory is website/.
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY . /usr/share/nginx/html
RUN rm -f /usr/share/nginx/html/Dockerfile /usr/share/nginx/html/nginx.conf /usr/share/nginx/html/railway.json /usr/share/nginx/html/READ-ME-FIRST.md /usr/share/nginx/html/.htaccess
EXPOSE 8080
