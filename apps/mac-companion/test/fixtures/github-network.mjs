const fetchFromNetwork = globalThis.fetch;
globalThis.fetch = (input, init) => {
  const url = new URL(input instanceof Request ? input.url : input);
  if (url.origin === "https://api.github.com")
    return Promise.reject(new TypeError("fetch failed"));
  if (url.href === "https://avatars.githubusercontent.com/test?s=80")
    return Promise.resolve(
      new Response("avatar fixture", {
        headers: { "Content-Type": "image/png" },
      }),
    );
  return fetchFromNetwork(input, init);
};
