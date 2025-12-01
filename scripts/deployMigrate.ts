import { CallData } from "starknet";
import { setup } from "../lib";

const deployer = await setup(process.env.NETWORK);

const [migrate, calls] = await deployer.deferContract(
  "Migrate",
  CallData.compile({
    singleton_v2: "0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160"!,
    migrator: "0x07bffc7f6bda62b7bee9b7880579633a38f7ef910e0ad5e686b0b8712e216a19"!
  }),
);

let response = await deployer.execute([...calls]);
await deployer.waitForTransaction(response.transaction_hash);

console.log("Deployed:", { migrate: migrate.address });
