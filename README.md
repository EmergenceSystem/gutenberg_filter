# gutenberg_filter

EmergenceSystem filter that searches Project Gutenberg for public-domain ebooks via the Gutendex API. No API key required.


<!-- emergence-context -->
Part of **[EmergenceSystem](https://github.com/EmergenceSystem)** — a distributed
discovery network of small, single-source agents. This filter joins the em_pop gossip
mesh and answers `POST /agent/query`; Emquest fans each query out to many filters in
parallel and aggregates the results.

## Input

```json
{"query": "moby dick"}
```

| Field     | Type    | Default | Description              |
|-----------|---------|---------|--------------------------|
| `query`   | string  | —       | Title or author name     |
| `timeout` | integer | `10`    | HTTP timeout in seconds  |

## Output

Up to 10 embryos, one per book:

```json
{
  "properties": {
    "url":    "https://www.gutenberg.org/ebooks/2701",
    "resume": "Melville, Herman",
    "title":  "Moby Dick; Or, The Whale",
    "source": "gutenberg.org"
  }
}
```

## Capabilities

`gutenberg`, `books`, `ebooks`, `public_domain`, `literature`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
