python3 overture_fetch.py --theme places --type place \
    --bbox -73.508,41.187,-69.858,42.887 \
    --require-postcode --require-website \
    --threads 16 -o out/ma_places.parquet \
    --where "addresses[1].region = 'MA'"