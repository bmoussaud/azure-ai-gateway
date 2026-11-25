FROM mcr.microsoft.com/powershell@sha256:2ace324aefd5f154068a23ea6131c6cd33dc9b704545e2dcef904df40b1f20a5 AS powershell
FROM mcr.microsoft.com/azure-cli@sha256:123feca19aa2b702a9abfe7d82e89452308bde429c49bce9e54648f9834a1e11
USER root
RUN tdnf install -y icu python3-pip && tdnf clean all
COPY --from=powershell /opt/microsoft/powershell/7 /opt/microsoft/powershell/7
COPY --from=powershell /usr/share/dotnet /usr/share/dotnet
ENV DOTNET_ROOT=/usr/share/dotnet
RUN ln -s /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh \
    && pwsh -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
WORKDIR /app
COPY console/requirements.txt ./console/requirements.txt
RUN python3 -m pip install --no-cache-dir -r ./console/requirements.txt
COPY scripts/ ./scripts/
COPY config/profiles/ ./config/profiles/
COPY observability/ ./observability/
COPY console/ ./console/
ENV PYTHONUNBUFFERED=1 AZURE_CONFIG_DIR=/tmp/azure DOTNET_CLI_TELEMETRY_OPTOUT=1
EXPOSE 8080
ENTRYPOINT ["python3", "/app/console/server.py"]
