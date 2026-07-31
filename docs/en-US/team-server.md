# Team Server

MXRB connects directly to official Team Server Git repositories and the App
Repository API without `mx`, Studio Pro, or the Model SDK:

```sh
mxrb team-server login --pat-file /secure/team-server.env
mxrb team-server clone APP_ID ./app
mxrb team-server branches APP_ID
mxrb team-server pull ./app
```

The recommended mode stores only the absolute PAT file path. Plain text, JSON,
and `.env` files containing `MXRB_TEAM_SERVER_PAT` are supported. The PAT is
read only for requests and passed to Git through a temporary `GIT_ASKPASS`
helper; it is never embedded in URLs, arguments, or `.git/config`.

Read requires `mx:modelrepository:repo:read`; push also requires
`mx:modelrepository:repo:write`. Mendix documents that external clones do not
receive all Studio Pro post-processing and revision metadata. MXRB validates
root MPR files after clone and pull, but cannot manufacture Mendix Cloud
revision metadata.

The repository `a9e4af8a-2776-4b10-a471-8c42df8f5f43` was queried through the
App Repository API and cloned over HTTPS. MXRB validated `MyFirstModule.mpr`,
detected `main`, and confirmed that the remote URL contained no PAT. The
temporary acceptance credential file was destroyed afterwards.
