FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG PROJECT
WORKDIR /src
COPY ${PROJECT}/ ${PROJECT}/
RUN dotnet publish ${PROJECT}/${PROJECT}.csproj -c Release -o /out

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /out .
ARG PROJECT
ENV PROJECT=${PROJECT} ASPNETCORE_URLS=http://+:8080
ENTRYPOINT ["sh", "-c", "exec dotnet ${PROJECT}.dll"]
