# Space «Великий & Могучий»: приём обновлений и выдача заданий. Собирается Hugging Face из папки, которую
# готовит space/deploy.py (код protocol/, hub/, space/ и server/ratelimit.py из репозитория).
FROM python:3.13-slim
RUN useradd -m -u 1000 user
WORKDIR /home/user/app
COPY --chown=user requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --chown=user . .
USER user
ENV HF_HOME=/tmp/hf PYTHONUNBUFFERED=1
EXPOSE 7860
CMD ["uvicorn", "space.app:app", "--host", "0.0.0.0", "--port", "7860", "--no-access-log"]
