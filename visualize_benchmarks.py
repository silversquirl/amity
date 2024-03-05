import numpy as np
import matplotlib.pyplot as plt

instance = np.load("zig-out/bin/bench_instance.npy")
storage = np.load("zig-out/bin/bench_storage.npy")

outliers = 10
instance = instance[outliers:-outliers]
storage = storage[outliers:-outliers]

plt.hist(instance, bins=1000, label="instance", histtype="step")
plt.hist(storage, bins=1000, label="storage", histtype="step")
plt.legend()
plt.show()
