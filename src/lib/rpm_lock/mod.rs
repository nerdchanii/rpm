mod constraint;
use std::{error::Error, fs::OpenOptions};

use constraint::LOCK_FILE_PATH;



#[derive(Debug, Clone, Serialize, Deserialize)]
struct Dependency {
    pkg: String,
    version: String,
    constraint: String,
}




#[derive(Debug, Clone, Serialize, Deserialize)]
struct LockFile {
    name: String,
    version: String,
    dependencies: Vec<Dependency>,
}

pub impl LockFile {
    fn new(name: String, version: String, dependencies: Vec<Dependency>) -> Self {
        Self {
            name,
            version,
            dependencies,
        }
    }

    fn save(&self) -> Result<(), Box<dyn Error>> {
        let lockfile = serde_json::to_string(&self)?;
        let mut file = File::create("rpm-lock.toml")?;

        file.write_all(lockfile.as_bytes())?;
        Ok(())
    }

    fn load(&self) -> Result<Self, Error> {
        let mut buffer = String::new();
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .open(LOCK_FILE_PATH)?;
        file.read_to_string(&mut buffer)?;
        let lock = buffer.parse::<Self>();
        let lockfile: Self::new()?;
    }
}
