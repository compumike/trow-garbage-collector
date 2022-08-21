# trow-garbage-collector

Automatic garbage collector for a [Trow](https://github.com/ContainerSolutions/trow/) registry.

Forked from the original [trow-garbage-collector](https://github.com/compumike/trow-garbage-collector) so LimePoint can apply a variety of fixes to correct the original.

The OpsChain API image registry GC Dockerfile (`build/image-registry-gc/Dockerfile`) uses `src/main.rb` from this repository. The build and deployment scripts from the original repository were unused and have been removed to avoid any confusion and/or maintenance effort. 

See the original [README](https://github.com/compumike/trow-garbage-collector/blob/master/README.md)
for more information on the original project.
