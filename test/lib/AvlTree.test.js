import chai from 'chai'
import chaiAsPromised from 'chai-as-promised'
import chaiBigNumber from 'chai-bignumber'

import { linkLibs } from '../helpers/utils'
import { AvlTree } from '../helpers/contracts'

// add chai pluggin
chai
  .use(chaiAsPromised)
  .use(chaiBigNumber(web3.BigNumber))
  .should()

contract('AvlTree', async function() {
  let avlTree

  beforeEach(async function() {
    await linkLibs()
    avlTree = await AvlTree.new()
  })

  it('should initialize properly', async function() {
    await avlTree.getRoot().should.equal(0)
    
    await avlTree.insertValue(50)
    await avlTree.insertValue(40)
    out = await avlTree.getRoot()
    console.log(out)

    // await avlTree.search(50).should.equal(true)
  })

  // it('should not allow to withdraw more than amount', async function() {
  //   await childToken.withdraw(web3.toWei(11)).should.be.rejected
  // })


 
})
