import os
import numpy as np
import matplotlib.pyplot as plt

data_dir = "zig-out/bin"

data = {}
outliers = 10
for path in os.listdir(data_dir):
    if path.endswith(".npy"):
        d = np.load(os.path.join(data_dir, path))
        d = d[outliers:-outliers]
        data[os.path.basename(path)] = d


for name, d in data.items():
    plt.hist(d, bins=1000, label=name, histtype="step")
plt.legend()
plt.show()
