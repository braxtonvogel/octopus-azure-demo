FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build
WORKDIR /src
COPY global.json .
COPY DemoApp/DemoApp.csproj DemoApp/
RUN dotnet restore DemoApp/DemoApp.csproj
COPY . .
RUN dotnet publish DemoApp/DemoApp.csproj -c Release -o /app

FROM mcr.microsoft.com/dotnet/aspnet:11.0
WORKDIR /app
COPY --from=build /app .
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "DemoApp.dll"]