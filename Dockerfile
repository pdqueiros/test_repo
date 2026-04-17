FROM python:3.13-slim AS build
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

RUN mkdir /app
COPY ./uv.lock /app/uv.lock
COPY ./pyproject.toml /app/pyproject.toml
COPY ./README.md /app/README.md

RUN echo $(grep -m 1 'version' /app/pyproject.toml | sed -E 's/version = "(.*)"/\1/') > /app/__version__

COPY ./src/ /app/src/
WORKDIR "/app"

ARG UV_INDEX_PASSWORD=""
ARG PYPI_INDEX_URL=""
RUN if [ -n "$PYPI_INDEX_URL" ] && [ -n "$UV_INDEX_PASSWORD" ]; then \
      export UV_EXTRA_INDEX_URL="https://oauth2accesstoken:${UV_INDEX_PASSWORD}@${PYPI_INDEX_URL#https://}"; \
    fi && \
    uv sync --all-extras
ENV PATH="/app/.venv/bin:$PATH"

FROM build
RUN apt-get autoremove -y && apt-get clean -y
