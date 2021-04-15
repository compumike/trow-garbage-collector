# trow-garbage-collector

Automatic garbage collector for a [Trow](https://github.com/ContainerSolutions/trow/) registry.

Identifies blobs in a that are not referenced by any tag manifests (such as `:latest`) and frees disk space.

WARNING: This will automatically delete blobs from your trow registry. This is alpha-grade software. It may delete the wrong blobs! It may delete layers you're actually using! If this happens, make sure you're able to push the images you need to the repository again, and please report an issue so we can fix it.

## One-line install

```shell
kubectl apply -f https://raw.githubusercontent.com/compumike/trow-garbage-collector/master/deploy.yml
```

This assumes you have a `trow-0` pod (i.e. from a StatefulSet) in a `trow` namespace.

## How it works

trow-garbage-collector is a small Ruby script which:

1. Reads the latest manifest JSON for every tag for every image.
1. Marks all blobs being specified by these manifest JSONs (as layers and configs) as in-use.
1. Any remaining blobs not mentioned from the latest manifest JSONs are not-in-use and are deleted from disk.

This process is repeated every `POLL_INTERVAL` seconds (currently 3600 s = 1 hour).

## Tag history vs. new tags

This type of garbage collection works well to reclaim space if you're repeatedly pushing builds to the same tag, such as `:latest`. If you're simply pushing new versions of your containers to `:latest`, then this is probably all you need.

However, if you are creating new tags on each build (such as with a version or commit id or hash), this type of GC won't help much because all of the old layers are still referenced by the old tags. You'll need to manually delete the old tags before this type of GC can help you.

## Common race conditions are avoided

If new images are being pushed into the registry at the same time as the GC runs, there is a chance that those blobs (layers) are uploaded before their corresponding manifest is uploaded, so the blobs would briefly be considered not-in-use, and therefore deleted by GC. To avoid this race condition, trow-garbage-collector applies a `MIN_GC_BLOB_AGE` (default 86400 s = 1 day) rule. Under the default setting, it will not delete any blobs which are less than 1 day old. This resolves almost all possible race conditions.

## Rare race condition

There remains a very unlikely possibility of a race condition. It's probably so rare that it will never happen. If there's a new image being uploaded that references an old layer, and the conditions are just right, the new image upload may succeed just as the old layer is deleted by GC.

Simultaneously, you'd need to have an upload that references an old layer; the old layer would have to have just crossed through the `MIN_GC_BLOB_AGE` since the last `POLL_INTERVAL`; the old layer would have to NOT be referenced by any current tags (in practice, very unlikely!); and the GC would have to be running at exactly the instant that the new image upload is happening. These would all have to happen together.

If you happen to experience this rare race condition, you'll simply notice that your clients are unable to pull the image, because they'll get a 404 on a particular layer blob. Just re-push your image to the registry and you'll be good to go.
